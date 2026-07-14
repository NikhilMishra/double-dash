# MKDD Game-Side Landscape — Technical Report

Research agent report, 2026-07-14. Confidence: **[Confirmed]** = directly sourced; **[Inferred]** = reasoned; **[Unknown]** = flagged for verification.

## 1. Decompilation

- **[Confirmed]** `github.com/doldecomp/mkdd` is the canonical decomp (started by SwareJonge; tracked at decomp.dev/SwareJonge/mkdd, ~34.8% as of mid-2026). Buildable & matching with decomp-toolkit/objdiff/ppcdis + ninja; user supplies disc image.
- **[Confirmed]** Targets the **DEBUG build only** (archive.org "Mario Kart: Double Dash!! (USA) (Prototype)"), not retail GM4E01 — insights must be ported to retail.
- **[Inferred]** At ~35%, coverage is mostly shared SDK/JSystem, not the race engine or LAN stack. Not shiftable.
- **[Confirmed]** `github.com/medsouz/mkdd-mod`: IDA RE project for retail — exports Dolphin `.map` symbol files + IDC scripts, `sda_base_labeler.py`, includes a working code-patch PoC. **Fastest route to named retail addresses.**

## 2. Native LAN mode internals

- **[Confirmed]** Up to 8 GameCubes / 16 players (4 per console), BBA required.
- **[Confirmed]** Frame-locked **lockstep**: over high-latency links it runs in slow motion and crashes under jitter/loss; community guidance ~20 ms ping; on real hardware via Nintendont "lags at 3 consoles, unplayable at 4."
- **[Confirmed]** Handshake: all players press Start simultaneously; counter counts to ~170; no late join. **[Inferred]** fixed-membership session, static per-frame input slots.
- **[Unknown]** Wire protocol (ports, discovery, packet layout) undocumented publicly. **[Inferred]** UDP + subnet broadcast discovery. Would need reversing (Dolphin BBA capture + mkdd-mod symbols) — NOT needed for our emulator-level approach.
- `github.com/Sir-LoLz/Improve-MKDD-netcode`: open bounty to fix LAN crashes; contains no protocol reversing yet.

## 3. Modding community & tooling

- **[Confirmed]** `mkdd.org` (Custom MKDD Wiki, ~793 articles, active 2024–2025): `List_of_Custom_Codes`, `Category:Code/Gecko`, "Boot Straight Into LAN Mode" Gecko code, "Item Cycler" (proves item RNG locatable), "MKDD LAN Edition" distribution.
- **[Confirmed]** `github.com/cristian64/mkdd-extender`: injects up to 144 custom courses; actively maintained; big content packs exist.
- **[Inferred]** No consolidated public retail RAM map (unlike MKW/Melee) — assemble from Gecko codes (addresses embedded), the mkdd-mod `.map`, and own work. Community coordination via Discord (links from mkdd.org / DDD README).

## 4. Determinism concerns

- **[Confirmed]** from Dolphin netplay practice: screen mode must match across peers or desync; **Mushroom City / Mushroom Bridge banned** in competitive netplay for desyncs (**[Inferred]** RNG-driven traffic AI); dual-core desyncs fixed by "deterministic dual core = fake completion."
- **[Confirmed]** Item/roulette RNG exists and is gameplay-critical. **[Unknown]** exact RNG algorithm/address — irrelevant for dirty-page snapshots (RNG state restored with memory), but relevant if we ever do targeted region maps.
- **[Inferred]** Core sim IS deterministic peer-to-peer — native lockstep LAN couldn't work otherwise. Good news for rollback.

## 5. Prior online-play attempts & adjacent prior art

- **Double Dash Deluxe** (`github.com/doubledashdeluxe/ddd`, AGPLv3): the only serious "real online for MKDD" effort. In-game code patch (runs on GC/Wii/Dolphin), derived from MKW-SP: `REPLACE`/`REPLACED` function patching (CodeWarrior + Rust/Python/LLVM tooling), UDP everywhere, Noise IK encryption, custom formats, single relay server. **Client-server with lag compensation, NOT rollback.** WIP, no releases. Mine for MKDD function offsets + transport ideas.
- **Project Rio** (Mario Superstar Baseball, projectrio.online): **Dolphin fork** + game-specific Gecko codes + Dolphin NetPlay (traversal server, lobby browser) + stats backend.
- **Mario Party Netplay** (`github.com/MarioPartyNetplay/Dolphin-MPN`): same pattern — Dolphin fork + codes + traversal netplay.
- **MKW-SP** (`github.com/mkw-sp/mkw-sp`, continued as `GnomedDev/mkw-spc`) / `stblr/mkw-cs`: the in-game client-server school DDD inherits.

**Two schools**: (1) emulator-side (Rio, MPN, Slippi = this school + rollback) — our path; (2) game-side patch (MKW-SP, DDD) — portable to console but not rollback.

**No existing MKDD project implements rollback — ours would be the first.**

## Key resources

- https://github.com/doldecomp/mkdd · https://decomp.dev/SwareJonge/mkdd · https://github.com/medsouz/mkdd-mod
- https://github.com/doubledashdeluxe/ddd (+ docs/design.md in that repo) · https://github.com/Sir-LoLz/Improve-MKDD-netcode
- https://www.teamxlink.co.uk/wiki/Mario_Kart:_Double_Dash!! · https://mkdd.org (wiki, codes) · https://github.com/cristian64/mkdd-extender
- https://www.projectrio.online · https://github.com/MarioPartyNetplay/Dolphin-MPN
- https://forums.dolphin-emu.org/Thread-mario-kart-double-dash-netplay-replay-fix (deterministic dual core)

## Open gaps

Exact RNG algorithm/address; retail-vs-debug symbol mapping; LAN wire format (unneeded for MVP); DDD's current status.
