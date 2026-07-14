# double-dash

**Slippi-style rollback netplay for Mario Kart: Double Dash!! (GameCube).**

The first rollback netcode project for MKDD: a fork of mainline Dolphin that lets two players
race online with rollback instead of delay-based input buffering — enter a connect code,
race, no slow-motion lockstep, no VPN ceremony.

## How it works (short version)

Both machines emulate the *same virtual GameCube* running local 2-player split-screen mode
(the Slippi / Project Rio model). Remote controller inputs are injected at Dolphin's pad-poll
level. When a remote input arrives that differs from the prediction, the emulator restores a
frame-accurate snapshot and re-simulates forward — dirty-page memory tracking keeps snapshots
around ~1 ms so this fits inside the 16.6 ms frame budget.

## Status

**Phase 0 — feasibility benchmarks.** See `docs/benchmarks.md` for the go/no-go gate numbers
and `docs/design.md` for the architecture. Research that grounds the design is in
`docs/research/`.

## Roadmap

| Phase | Deliverable | Gate |
|---|---|---|
| 0 | Fork builds; benchmark numbers | Dirty-page save ≤ ~2 ms; 7-frame resim ≤ ~2 frame budgets |
| 1 | Offline rollback core | 3-lap race under simulated 60–100 ms RTT, no desync, 60 fps |
| 2 | Real networking (UDP + traversal + codes) | Full cup with a real friend over real internet |
| 3 | Packaging + UX | Friend goes zip → in-race in <10 min |

Post-MVP: 3–4 players, full-screen-per-player, desync-track fixes, connect-code service, replays.

## Legal

This project contains no game assets or copyrighted code. You must dump your own
Mario Kart: Double Dash!! disc (GM4E01); both players need byte-identical dumps.
The Dolphin fork is GPLv2+ like upstream Dolphin.
