# Architecture (living document)

Last updated: 2026-07-14 (Phase 1 — rollback core proven, control loop built + unit-tested)

## Model

Both peers emulate the **same virtual GameCube** running MKDD's local 2-player split-screen
mode. This is the Slippi/Project Rio school: netcode lives in the emulator, not the game.

- **Input plane**: local pads are read normally; the remote player's `GCPadStatus` is injected
  at Dolphin's pad-poll (SI) level. No game-side ASM required for the MVP.
- **Prediction**: remote input for un-received frames = last received input (kart controls are
  highly continuous, so hold-last predicts well).
- **Rollback**: on misprediction, restore the snapshot of the last confirmed frame and
  re-simulate to the present with corrected inputs. Target window: 7–10 frames.
- **Rendering**: split-screen, both views on both machines (couch semantics). Full-screen-per-
  player is post-MVP (requires game patching; mine `medsouz/mkdd-mod` symbols).

## Snapshots: dirty-page tracking, not region maps

Slippi hand-reverse-engineered a Melee memory-region list to get ~1 ms savestates. We instead
track dirty pages generically:

- Track dirtied 4 KiB pages per frame via Windows `GetWriteWatch` (see the arena problem
  below); same idea as Dolphin draft PR #12911 and `FaultyPine/incremental-rollback`.
- Per-frame delta = dirtied pages + small serialized non-RAM subsystem state (CPU regs,
  scheduler events, SI/EXI, DSP) via a targeted fast path that must NOT flush the JIT cache.
- Ring buffer of deltas covering the rollback window; restore = walk deltas back to frame N.
- Full-memory deltas restore RNG and all game state automatically — zero game-specific
  memory knowledge needed. This is the key simplification vs. Slippi.

Measured cost model (Phase 0, `docs/benchmarks.md`): `snapshot_ms ≈ 0.15 + dirty_pages × 0.75 µs`.
It is pure memory bandwidth — 8 KiB of traffic per dirty page at this machine's single-core
cold-copy ceiling (10.6 GiB/s). Coalescing contiguous dirty runs into single memcpys and
de-duplicating pages across the restore window are load-bearing (1.6x / 3x), not optional.
At a Brawl-like ~1000 dirty pages/frame this is ~0.9 ms — parity with Slippi's savestate,
without Slippi's months of game-specific reverse engineering.

### The arena problem (found 2026-07-14, corrects the original plan)

**`MEM_WRITE_WATCH` cannot be applied to Dolphin's emulated RAM as mainline allocates it.**
`Source/Core/Common/MemArenaWin.cpp` backs guest memory with a *pagefile-backed section*
(`CreateFileMapping(INVALID_HANDLE_VALUE, …)`) and maps views of it with `MapViewOfFileEx` /
`MapViewOfFile3`. It must: fastmem mirrors the same physical memory at several virtual
addresses (GC MEM1 is visible cached at 0x8000_0000 and uncached at 0xC000_0000), and only a
shared section can be mapped twice. But `MEM_WRITE_WATCH` is a `VirtualAlloc` flag for
**private** committed memory and does not work on mapped views. So write-watch is *not* a
drop-in on stock Dolphin.

**What the prior art actually is** (read the source, 2026-07-14 — an earlier note here, based on
a summary rather than the code, was wrong): `FaultyPine/incremental-rollback` is **not a Dolphin
fork**. It is a standalone synthetic benchmark, much like our `tools/bench/`. Its author did
separately patch Dolphin — "replaced Dolphin's allocation logic with a single call to allocate a
big block of (tracked) memory" — but only to *measure* Brawl's dirty-page count (~1500/frame),
and they explicitly **left the fastmem regions out** of the tracked block. (The README's "custom
fastmem implementation" refers to *Dolphin's* fastmem, not one they wrote.) Its ~1 ms / ~16 ms
figures are synthetic, not from a working rollback build.

So **no working implementation of this exists to copy.** We are building it.

The seam that makes it tractable: Dolphin already ships a **`MAIN_FASTMEM_ARENA`** config
(`Config::MAIN_FASTMEM_ARENA`, exposed in the UI as "Disable Fastmem Arena") that is separate
from `MAIN_FASTMEM` and `MAIN_PAGE_TABLE_FASTMEM`. With the fastmem *arena* off,
`InitFastmemArena()` never runs, no aliased mirror views are created, and guest memory is
reached only through the anonymous `CreateView` pointers (`m_ram`, `m_l1_cache`, `m_fake_vmem`).
**Aliasing is what forces the shared section — remove the requirement and private
write-watched memory becomes legal.** Page-table fastmem can remain on, so we do not fall all
the way back to the slow interpreter path.

Options — **measured, and the ranking flipped (2026-07-14):**

1. ~~**Tracked-arena mode**~~ (built and measured; **rejected for the rollback runtime**): with
   `FASTMEM_ARENA` off, back the arena with one private `VirtualAlloc(MEM_WRITE_WATCH)` block and
   make `CreateView` return `block + offset`. Snapshots are cheap (~0.6 ms at MKDD's ~700 dirty
   pages/frame). **But disabling the fastmem arena costs ~7× emulation speed** — MKDD drops from
   ~400% to ~53% of realtime (`docs/benchmarks.md`), below realtime before rollback resim is even
   added. The cheap snapshot does not come close to paying for that. Kept in-tree as a measurement
   tool; potentially revivable on Linux, where soft-dirty (`/proc/pid/pagemap`) tracks aliased
   memory without disabling fastmem.
2. **Full guest-RAM copy each frame (NOW THE PLAN).** Keep the fastmem arena fully on (stock
   memory path, ~400% speed) and snapshot by copying MEM1 (24 MiB → ~2.2 ms/frame at 10.6 GiB/s)
   into a ring buffer. No arena surgery, no game-specific memory map, and — the deciding factor —
   emulation and resim run at full fastmem speed. ~4 ms emulate + ~2.2 ms copy ≈ 6.2 ms/frame,
   well under budget. Optimizations if needed: copy across threads, or narrow the copied range
   once a memory map exists.
3. **Slippi-style targeted region copy.** Copy only known MKDD gameplay regions each frame. Needs
   a reverse-engineered MKDD memory map — the months of work we are avoiding. Fallback only if
   full-copy's per-frame tax proves too high (it should not, given the speed headroom).

**Known risk (unchanged)**: mainline's savestate *load* is dominated by the PowerPC namespace
(~55–60 ms — likely JIT/icache invalidation). The restore path must not flush the JIT cache.

## Rollback loop (Phase 1)

Two layers, so the tricky part is testable without the emulator.

### Layer 1 — the control algorithm (built + proven, `Core/Rollback/`)

Pure, header-only, no Dolphin dependencies, exhaustively unit-tested (`UnitTests/Core/RollbackSessionTest.cpp`, 9 tests incl. a randomized delay/jitter/window sweep proving equivalence to perfect information):

- **`InputBuffer<Input>`** — per-port ring of inputs, each slot `Empty | Predicted | Real`.
  - *Prediction* for an un-received remote frame = repeat that port's most recent real input
    (kart controls are continuous, so hold-last is right most of the time).
  - *Misprediction* = a real input arrives for a frame we already simulated with a **different**
    prediction. `AddRemoteInput` returns exactly that boolean — the rollback trigger. Inputs that
    arrive *before* we simulate their frame (the input-delay happy path) can never mispredict.
  - Tracks each port's contiguous-real high-water mark; `ConfirmedFrame()` = min across ports =
    the newest frame safe to release (no rollback can reach before it).
- **`RollbackSession<Input, Game, NumPorts>`** — the loop, over a caller-supplied `Game` backend
  (`Capture`/`Restore`/`Step`). Invariant it enforces: *predict-and-correct yields the exact state
  that having every input up front would have.* Frame convention: snapshot for frame F is the state
  **before** F. `MaybeRollback()` restores the snapshot at the earliest bad frame and re-simulates
  forward to the present; `AdvanceFrame()` snapshots then steps once. Both go through one
  `SimulateFrame` so normal advance and re-sim have identical ordering.

The snapshot ring holds `window + 2` states; `window` is the deepest rollback (size it above
worst-case network delay in frames). For the Dolphin backend the snapshot is heavy, so `window`
stays small (≈8–10) and the trimmed snapshot size sets the memory cost (e.g. 10 × ~24 MB target).

### Layer 2 — the Dolphin backend (next)

The `Game` backend for real emulation:

- **`Capture`/`Restore`** — reuse the proven `Rollback::Snapshot` (full-copy, fastmem-arena on,
  JIT-clear skipped on restore). Already validated in Phase 1's determinism work.
- **`Step` = advance exactly one emulated frame.** Feasible **in single-core**: the CPU-GPU thread
  is the only sim thread and `PowerPCManager::RunLoop()` returns synchronously when
  `CPUManager::Break()` fires from the field-boundary callback (`Core::Callback_NewField` →
  `CPU::Break`, the same primitive `DoFrameStep` uses). So "run to the next field boundary and
  stop" exists; the rollback driver calls it N times to re-simulate. Dual-core would additionally
  need a GPU-queue fence per step (`AsyncRequests::WaitForEmptyQueue`), so **the loop is built in
  single-core first.**

  Concrete structure (worked out from the run loop, not yet coded): the driver must live at
  `CPUManager::Run`'s level, **not** inside `OnFrameEnd`, or re-simulating would re-enter
  `RunLoop`. Plan: branch `CPUManager::Run`'s `State::Running` case — when a match is active, run a
  rollback loop instead of the bare `power_pc.RunLoop()`. Each iteration: capture the pre-frame
  snapshot, arm a one-shot field-boundary break (a rollback flag alongside `s_frame_step` in
  `Callback_NewField`), call `power_pc.RunLoop()` (returns after one field), then run the post-frame
  logic (advance the session; on a late remote input, restore + call the one-frame primitive N times
  to catch up invisibly). Because `Break()` leaves CPU state in `Stepping`, the loop resets it to
  `Running` before the next frame. Validate headless first: a self-test that does a *synchronous*
  restore+resim through this primitive and checks the guest-RAM hash matches the straight run
  (the emulator-side analogue of the passing `RollbackSession` unit test).

- **`RollbackManager` + injection seam (landed, inert).** `Core/Rollback/RollbackManager` exposes
  `IsMatchActive()` and `GetInput(system, port, GCPadStatus*)`, wired into
  `CSIDevice_GCController::GetPadStatus` ahead of the local-poll/movie/netplay path. It returns
  false until a match runs, so it is a verified no-op on stock emulation. The run loop above fills
  in the match-active path.
- **Input injection** — override the pad at `CSIDevice_GCController::HandleMoviePadStatus`
  (`SI_DeviceGCController.cpp`), ahead of the netplay branch, overwriting `*pad_status` exactly as
  `Movie::PlayController` does. A `Rollback::GetInput(port, GCPadStatus*)` returns false (no-op)
  until a match is running, mirroring how the Movie/NetPlay hooks sit inert.
- **Input type** — a `RollbackPad` wrapping only the deterministic `GCPadStatus` fields (buttons,
  sticks, triggers), **not** host-only noise like `err`/`isConnected`, with `==` for misprediction
  checks and a compact wire encoding (reused in Phase 2).

### Phase 1 gate and the local latency harness

Before any networking, prove the loop against a **local fake-remote**: feed player 2's inputs to
the session with a configurable delay + jitter, so prediction/rollback runs for real with no
sockets. Gate: a 3-lap race under simulated RTT with no visible desync at 60 fps. This is the
emulator-side analogue of the unit test's equivalence property.

### Desync detection must exclude host-timed scratch

Phase 1's determinism hunt (see `benchmarks.md`) proved the MKDD simulation is deterministic
except for a bounded, non-cascading handful of bytes in two fixed host-timed leaf buffers
(≈`0x8037_611f`, `0x8048_c3xx` — audio/DTK streaming scratch the sim never reads back). The
peer-to-peer desync-detection checksum (Phase 2) must therefore hash **game-logic RAM and exclude
these regions**, or peers will false-alarm on cosmetic bytes. Rollback re-simulation itself is
unaffected: those bytes never feed the sim, so they cannot change gameplay.

## Networking (Phase 2)

- UDP peer-to-peer; each packet carries the last N frames of inputs (redundancy beats
  retransmission at this scale).
- Clock sync / frame advantage smoothing, tunable input delay (default 2 frames, Slippi-style).
- NAT traversal: reuse Dolphin's traversal client/server; host codes for direct connect.
- Handshake verifies ISO hash, fork version, settings digest before starting.
- Desync detection: periodic exchanged state checksums; hard-stop with clear error on mismatch.

## Determinism requirements (same as stock Dolphin netplay for MKDD)

- Byte-identical GM4E01 dumps, identical fork version and settings (enforced by handshake).
- Deterministic dual core ("fake completion") or single core.
- Same-arch x64 peers initially (JIT float determinism).
- Track denylist until fixed: Mushroom City, Mushroom Bridge (traffic-AI desyncs known from
  stock netplay).

## Fork discipline

- Base: current mainline `dolphin-emu/dolphin` master. Slippi's 3-year Ishiiruka migration is
  the anti-pattern — rebase frequently, keep the delta patch-shaped, isolate rollback code
  behind interfaces (new files > edits to hot upstream files).
- Candidate upstream contribution: opt-in dirty-page savestate mode (PR #12911 territory).
- Unwind mainline's "no savestate loads during netplay" guard for our path.

## References

See `docs/research/` — slippi.md (rollback/EXI/savestate internals), mkdd.md (game-side
landscape, determinism, prior art), dolphin.md (savestate/netplay/BBA infra, benchmarks).
