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

## Next — toward a playable build

1. **Performance.** A full snapshot every frame currently costs ~8–10 ms and a rewind ~20 ms; a
   worst-case 7-frame rewind of a busy scene is ~130 ms today. Steady-state play looks like it fits
   60 fps, but deep/frequent rewinds would hitch. Two levers: shrink the snapshot (~57 MB → target
   ~24 MB) and skip rendering during the invisible replay frames.
2. **Wire real input + a local latency test** — you play, a fake "remote" player's inputs arrive
   with simulated lag, and rollback runs for real. **This is the first build you test by playing**,
   and the Phase 1 finish line (3-lap race, no desync, 60 fps).
3. Then Phase 2: real networking.

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
