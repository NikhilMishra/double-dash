# Slippi Rollback Netcode — Technical Report

Research agent report, 2026-07-14. Basis for our architecture; see `docs/design.md`.
Confidence markers: **[Confirmed]** = sourced from project-slippi repos/wiki/FAQ/dev writeups; **[Inferred]** = synthesis.

## 1. Architecture: repos and how they fit together

Slippi is a game-side ASM layer, an emulator fork, a Rust sidecar, and a launcher, communicating over a fake hardware device. Core author: Fizzi (Jas Laferriere), with UnclePunch, Nikki, metaconstruct.

**[Confirmed]** Repos (github.com/project-slippi):

| Repo | Language | Role | License |
|---|---|---|---|
| Ishiiruka | C++ | Original Dolphin fork (`slippi` branch): matchmaking comms, `.slp` replay writing, passing data into the game, savestates/rollback orchestration | GPL-2.0 |
| dolphin | C++ | Newer mainline-Dolphin-based fork; first beta `v4.0.0-mainline-beta.1` | GPL-2.0(+) |
| slippi-ssbm-asm | PPC ASM | Game-side mods injected into Melee. Codesets: Online, Recording, Playback, Common. Built with the Gecko assembler | GPL-3.0 |
| slippi-rust-extensions | Rust | Sidecar linked into Dolphin via C FFI (`slprs_` symbols). Modules: dolphin, exi, ffi, game-reporter, jukebox, user | GPL-2.0 |
| slippi-launcher | TS/Electron | Desktop hub: Dolphin updater, netplay launcher, replay viewer | GPL-3.0 |
| slippi-js | TS | `.slp` parsing/stats | — |
| slippi-wiki | Docs | GETTING_STARTED.md, SPEC.md (.slp format) | — |

**[Confirmed]** Flow (slippi-wiki/GETTING_STARTED.md): launcher launches the fork with a Melee 1.02 ISO → Dolphin injects slippi-ssbm-asm mods on boot → game ASM and Dolphin exchange state via EXI (`Source/Core/Core/HW/EXI_DeviceSlippi.cpp`) → rollback is "work done between the Slippi SSBM ASM code and the Ishiiruka code" → Rust extensions link via C FFI ("Dolphin (C++) → ffi (C) → EXI (Rust)").

**Ishiiruka vs mainline [Confirmed]**: original base was Faster Melee's Ishiiruka (itself based on very old Dolphin). Rebasing onto modern mainline took ~3 years (v4.0.0-mainline-beta.1, 2023-10-18). Rust extensions carry `ishiiruka` and `mainline` feature flags.

**License [Confirmed]**: Dolphin is GPLv2+. Any fork is a GPL derivative and must ship source.

## 2. The rollback mechanism

### Savestates (the hard part)

**[Confirmed]** Dolphin's built-in savestates were not performant enough for per-frame rollback; Fizzi reverse-engineered in-game state generation. `SlippiSavestate.cpp` does selective region-based memory copies (`backupLocs`), e.g.:
- `0x80005520–0x80005940` (data)
- `0x803b7240–0x804DEC00` (data/BSS)
- `0x8065c000–0x8071b000`
- `0x80bd5c40–0x811AD5A0` (heap, dynamic size)

Explicitly excludes audio/sound memory and XFB/VI framebuffer memory. Constructor pre-allocates aligned buffers; `Capture()` copies RAM→buffers; `Load()` restores. Pools: `availableSavestates`/`activeSavestates` sized to `ROLLBACK_MAX_FRAMES`. Save+load ≈ 1 ms.

**[Inferred]** This region map is the single most Melee-specific piece — for another game it must be rebuilt from scratch (or replaced with dirty-page tracking, our approach).

### Input injection & game↔emulator communication

**[Confirmed]** Custom EXI device (`EXI_DeviceSlippi`): the game-side ASM (injected via Dolphin's Gecko/INI system, `GALE01r2.ini`) reads/writes a fake serial peripheral. Command-byte driven (opcode + payload per frame). Key functions: `configureCommands()`, `prepareFrameData()`, `checkFrameFullyFetched()`, `frameSeqIdx`.

**[Confirmed]** Model: predict remote inputs; on real-input mismatch, load last correct savestate and re-simulate. Delay tunable ("1 delay frame = 4 buffer"; default 2 delay frames good to ~130 ms). ~1.5 frames of Melee's internal visual delay removed, 2 added back for CRT feel.

## 3. Melee-specific vs. generic

**Must be rebuilt for another game**: savestate region map; all of slippi-ssbm-asm (every hook targets Melee addresses); RNG/determinism fixes; `.slp` spec/stats/playback.

**Transfers**: EXI-device transport pattern; rollback controller (predict → savestate → resim); savestate pooling; delay-frame logic; rust-extensions structure; launcher; fork/build mechanics.

**[Inferred]** Dominant cost for a new game = reverse-engineering the game (deterministic memory map + hooks), not writing netcode.

## 4. Matchmaking / infrastructure

**[Confirmed]** Official matchmaking/user server is closed-source. Flow (from OpenMelee's RE): HTTP user-discovery service keyed by `uid` in `user.json` (connect code, name, version) → ENet-based matchmaking exchanging JSON → P2P gameplay. Connect codes (`NAME#123`) are the identity primitive. Server endpoints hardcoded in the emulator.

**Open reimplementation**: `panchaea/openmelee` (alpha, Rust) — user discovery + ENet matchmaking.

## 5. Determinism / desync handling

**[Confirmed]** (Fizzi, "Fighting Desyncs in Melee Replays"):
- Melee RNG = single 32-bit seed; Slippi backs up/restores the seed with each player's inputs multiple times per frame; "frame start" event transfers the seed at frame beginning.
- Task-priority zones: input at pri3, particles (RNG consumers) at pri15; restoring RNG at pri0 extends the deterministic window over pri0–15.
- Uninitialized-memory bugs cause desyncs (e.g., Yoshi's Story Shy Guy count); fix = zero-init structs at game start.
- During re-sim, Slippi forcibly overwrites character state each frame; transient visual artifacts during the "resync" window.
- Gecko-code denylist (`prepareGeckoList()`) blocks non-deterministic cheats.

## Key sources

- https://github.com/project-slippi — Ishiiruka, slippi-rust-extensions, slippi-ssbm-asm, slippi-launcher, dolphin
- https://github.com/project-slippi/slippi-wiki/blob/master/GETTING_STARTED.md
- https://github.com/project-slippi/Ishiiruka/blob/slippi/Source/Core/Core/HW/EXI_DeviceSlippi.cpp
- https://medium.com/project-slippi/fighting-desyncs-in-melee-replays-370a830bf88b
- https://github.com/project-slippi/slippi-launcher/blob/main/FAQ.md
- https://github.com/panchaea/openmelee
- https://www.ssbwiki.com/Project_Slippi

## Gaps / caveats

- Exact EXI command-byte protocol and current savestate addresses: read `SlippiSavestate.cpp`, `EXI_DeviceSlippi.cpp`, and slippi-ssbm-asm `Online/` directly when needed.
- Whether the mainline fork changed savestate/rollback internals vs. Ishiiruka: unverified.
