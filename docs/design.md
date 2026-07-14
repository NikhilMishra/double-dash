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

- Allocate the emulated-RAM arena with `MEM_WRITE_WATCH`; use `GetWriteWatch` per frame to
  collect dirtied 4 KiB pages (~1 ms proven for Brawl by `FaultyPine/incremental-rollback`;
  same idea as Dolphin draft PR #12911).
- Per-frame delta = dirtied pages + small serialized non-RAM subsystem state (CPU regs,
  scheduler events, SI/EXI, DSP) via a targeted fast path that must NOT flush the JIT cache.
- Ring buffer of deltas covering the rollback window; restore = walk deltas back to frame N.
- Full-memory deltas restore RNG and all game state automatically — zero game-specific
  memory knowledge needed. This is the key simplification vs. Slippi.

**Known risk**: mainline's savestate *load* cost is dominated by the PowerPC namespace
(~55–60 ms — likely JIT/icache invalidation). Phase 0 profiles this; the fast path must keep
restore ~1 ms. FaultyPine's numbers show it's achievable.

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
