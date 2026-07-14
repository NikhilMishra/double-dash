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

Measured cost model (Phase 0, `docs/benchmarks.md`): `snapshot_ms ≈ 0.3 + dirty_pages × 2.2 µs`.
It is pure memory bandwidth — 8 KiB of traffic per dirty page at this machine's single-core
cold-copy ceiling. Coalescing contiguous dirty runs into single memcpys and de-duplicating
pages across the restore window are load-bearing (1.6x / 3x), not optional.

### The arena problem (found 2026-07-14, corrects the original plan)

**`MEM_WRITE_WATCH` cannot be applied to Dolphin's emulated RAM as mainline allocates it.**
`Source/Core/Common/MemArenaWin.cpp` backs guest memory with a *pagefile-backed section*
(`CreateFileMapping(INVALID_HANDLE_VALUE, …)`) and maps views of it with `MapViewOfFileEx` /
`MapViewOfFile3`. It must: fastmem mirrors the same physical memory at several virtual
addresses (GC MEM1 is visible cached at 0x8000_0000 and uncached at 0xC000_0000), and only a
shared section can be mapped twice. But `MEM_WRITE_WATCH` is a `VirtualAlloc` flag for
**private** committed memory and does not work on mapped views. So write-watch is *not* a
drop-in on stock Dolphin.

Prior art confirms and resolves this: `FaultyPine/incremental-rollback` "replaced Dolphin's
allocation logic with a single call to allocate a big block of (tracked) memory," which in
turn forced them to write their **own fastmem implementation**. So the work is real but proven.

Options, in preference order:
1. **Replace the arena with private write-watched memory + custom fastmem** (the
   incremental-rollback path). Keeps the generic no-RE-needed snapshot design. Read their
   source before writing ours.
2. **Run with fastmem disabled** over a flat write-watched arena. Much simpler, no mirroring
   problem, but costs emulation speed — and resim frames are exactly where we cannot afford
   it. Viable fallback if (1) proves too invasive.
3. **Slippi-style targeted region copy.** No dirty tracking at all; copy known MKDD gameplay
   regions every frame. Bandwidth cost is comparable, but it needs a reverse-engineered MKDD
   memory map (the months of work we were trying to avoid). Last resort.

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
