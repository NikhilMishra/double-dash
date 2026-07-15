# Double Dash Rollback — Progress

**Goal:** play *Mario Kart: Double Dash!!* online with a friend, seamlessly — a Slippi-style
Dolphin fork with rollback netcode (predict the other player's inputs, and silently re-simulate
when a guess was wrong).

**Status: Phase 2 (networking). Two computers can now run the same race in perfect lockstep over a
network connection — the core of online play is working. What's left is making it work between
*different* machines (not just two windows on one PC) and hardening the connection.**

---

## The plan, in four phases

| Phase | What it is | Status |
|------|------------|--------|
| **0. Feasibility** | Prove snapshotting the game 60×/sec is fast enough | ✅ **Done** |
| **1. Rollback engine** | Snapshot + predict + re-simulate, single machine | ✅ **Done** |
| **2. Networking** | Real internet play, connect-by-code, NAT traversal | 🔨 **In progress** |
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

## The rollback loop is smooth — a stutter bug was found and fixed ✅

The full loop runs the live game end-to-end: it polls your controller, feeds in the other player,
snapshots every frame, and silently rewinds + replays on a wrong guess. It was hitching badly at
first (~250 ms per rewind). The cause turned out **not** to be the snapshot copy but a hidden one:
every rewind was throwing away the emulator's compiled-code cache, forcing it to recompile the whole
game for one frame. Teaching the rewind to keep that cache dropped a rewind from **~48 ms to ~10 ms**
and unlocked a smooth 60 fps — and the low input-delay we actually want. (Details: `benchmarks.md`
Parts 7–9.)

## Phase 2 — two peers in perfect lockstep 🔨

**The milestone that makes it "online":** two separate copies of the emulator now run the *same* race
in exact byte-for-byte lockstep, exchanging controller inputs over a network connection. Verified
their game memory is **identical at frame 1 and still identical 900 frames later — zero desyncs over
1000+ frames**, at a locked ~60 fps.

Getting two independently-started copies to agree took three fixes, each a known cause of "it works
alone but desyncs together":

1. **Same starting point.** The two copies boot to slightly different moments, so one hands its exact
   machine state to the other at match start — now they begin identical.
2. **Deterministic mode.** The emulator has a strict mode (used by its own netplay) that makes audio,
   graphics, and timing reproducible frame-for-frame; it's now switched on for rollback play.
3. **Matching hardware setup.** The two copies had different memory cards plugged in, which alone was
   enough to snowball into a desync — both now run card-less (matching memory cards is a later nicety).

**You can try it now:** `tools/play-local.ps1` opens two windows on one PC in a shared race — focus a
window to drive its player (host = P1, guest = P2), one controller + Alt-Tab works.

## Next — real cross-machine play

The shared-start handoff currently uses a file, which only works for two windows on the *same* PC.
The remaining work for internet play: send that handoff **over the network**, harden the connection
(packet loss, jitter, reconnect), and connect-by-code / NAT traversal.

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
