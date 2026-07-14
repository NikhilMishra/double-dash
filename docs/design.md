# Architecture (living document)

Last updated: 2026-07-14 (Phase 0)

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

Options, in preference order:
1. **Tracked-arena mode**: with `FASTMEM_ARENA` off, back the arena with one private
   `VirtualAlloc(MEM_WRITE_WATCH)` block and make `CreateView` return `block + offset` (pointer
   arithmetic, no mapping). Small, contained delta to `MemArenaWin.cpp`. Costs some emulation
   speed vs. arena fastmem — measure it, since resim frames are where we can least afford it.
2. **Keep arena fastmem; drop OS dirty bits.** Copy guest RAM wholesale each frame (MEM1 is only
   24 MiB → ~2.2 ms single-threaded, likely <1 ms across threads). No arena surgery at all.
   Worth benchmarking as a serious contender if (1)'s fastmem loss proves expensive.
3. **Slippi-style targeted region copy.** No dirty tracking; copy known MKDD gameplay regions
   every frame. Needs a reverse-engineered MKDD memory map — the months of work we are trying to
   avoid. Last resort.

**Known risk (unchanged)**: mainline's savestate *load* is dominated by the PowerPC namespace
(~55–60 ms — likely JIT/icache invalidation). The restore path must not flush the JIT cache.

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
