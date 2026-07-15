# Double Dash Rollback — Progress

**Goal:** play *Mario Kart: Double Dash!!* online with a friend, seamlessly — a Slippi-style
Dolphin fork with rollback netcode (predict the other player's inputs, and silently re-simulate
when a guess was wrong).

**Status: Phase 1 (the rollback engine). The hard correctness questions are answered and the
control logic is proven; wiring it into the live emulator is underway.**

---

## The plan, in four phases

| Phase | What it is | Status |
|------|------------|--------|
| **0. Feasibility** | Prove snapshotting the game 60×/sec is fast enough | ✅ **Done** |
| **1. Rollback engine** | Snapshot + predict + re-simulate, single machine | 🔨 **In progress** |
| **2. Networking** | Real internet play, connect-by-code, NAT traversal | ⬜ Not started |
| **3. Polish** | Packaging, setup UX, controller config | ⬜ Not started |

---

## What's proven and working today

- **The fork builds and runs the game.** A real Dolphin fork (`NikhilMishra/dolphin`), boots and
  plays MKDD from a verified-clean disc image.
- **Fast state snapshots.** We can capture and restore the full machine state each frame cheaply
  (~8–10 ms capture, ~10–18 ms restore) with the fastmem speed path left on — fast enough for
  rollback. Restore is **byte-perfect every time** (0 failures in 500+ tries).
- **The game simulates deterministically.** This was the make-or-break question. After a rigorous
  hunt, an intermittent ~5% mismatch turned out to be a few bytes of **audio-streaming scratch**
  that never affects gameplay (it never grows or spreads, and matches the fact that stock Dolphin
  netplay already runs MKDD without desyncs). **Conclusion: the simulation is deterministic — the
  foundation rollback needs.**
- **The rollback logic is proven correct.** The prediction + re-simulation algorithm is built and
  covered by **13 automated tests**, including a randomized stress test that confirms
  *predict-and-rollback produces byte-for-byte the same result as if every input were known in
  advance.* This is the core guarantee of rollback netcode.
- **The input-injection seam is in place** — the exact hook the netcode uses to feed a remote
  player's controller into the game, sitting inert (no effect) until a match starts.

## The run loop — built and validated ✅

The **frame-driven run loop** is the engine piece that makes the emulator advance exactly one frame
at a time, so when a late input arrives it can rewind and replay several frames *invisibly* before
the next frame is shown. Both halves are now proven headless on the live game:

- **"Run one frame and stop" primitive** — driving the game frame-by-frame is bit-identical to
  running it normally and costs no speed (211 fps driven vs 224 fps free, within noise).
- **Synchronous rewind + replay** — restoring an earlier frame and re-running several frames *in one
  burst* reproduces the exact same game state **61 out of 61 times**. This is the core rollback
  operation, working end-to-end in the emulator.

**So the rollback mechanism is correct.** What's left before it's playable is (a) performance tuning
and (b) connecting it to real controller input.

## The full loop is wired and runs — but it's snapshot-bound ⚠️

The complete rollback loop now runs the live game end-to-end: it polls your controller, predicts a
(local, simulated-lag) second player, snapshots every frame, and rolls back for real on
mispredictions. Headless it **boots, runs, and is correct** — rollbacks stay bounded to the
simulated latency, no desync.

**But it's not smooth yet.** Taking a full snapshot every frame costs ~19 ms, which caps it at
~41 fps and turns each rollback into a ~250 ms hitch. Everything traces to one thing: the snapshot
is ~57 MB and copied through Dolphin's general-purpose save machinery 60×/second.

## Next — make the snapshot fast (the gate to 60 fps)

The snapshot must drop from ~19 ms to under ~10 ms. Levers, in order of payoff:
1. **Trim it to just the simulation state** (~57 MB → ~24 MB) — skip the audio (ARAM, 16 MB) and
   video host-cache serialization. These broke the *exact-match* determinism check before, but only
   in a few cosmetic bytes; the work is to confirm gameplay stays identical with them out, then keep
   them out.
2. **Skip rendering during the invisible replay frames.**
3. Faster copy (non-temporal stores).

Once snapshots are fast: play a 3-lap race under simulated lag at 60 fps (**Phase 1 finish line**),
then Phase 2 networking.

---

## Notable decisions & findings

- **Generic snapshots, not game-specific reverse engineering.** Slippi spent months mapping Melee's
  memory by hand; we snapshot the whole machine generically, so no MKDD-specific memory map is
  needed.
- **Full-copy snapshots** (keep the speed path on) beat dirty-page tracking, which turned out to
  cost ~7× emulation speed on Windows — measured, then rejected.
- **Single-core first.** The rollback loop is being built in single-core mode (simplest,
  deterministic); dual-core is a later optimization.
- **Controller:** Xbox pads work out of the box.
- **Provenance note:** real online play will require each player to supply their own byte-identical
  disc dump.

*Full technical detail: `docs/design.md` (architecture) and `docs/benchmarks.md` (measurements).*
