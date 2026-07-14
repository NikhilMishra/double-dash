# Dolphin Infrastructure & Rollback Feasibility — Technical Report

Research agent report, 2026-07-14. Confidence: **[CONFIRMED]** = Dolphin source/PRs/docs; **[INFERENCE]** = synthesis/estimate; **[UNVERIFIED]** = must measure.

## 1. Savestate system (`Source/Core/Core/State.cpp`)

- **[CONFIRMED]** Serialization via `PointerWrap` (`PointerWrap.h`) recursive `DoState(Core::System&, PointerWrap&)` over every subsystem; modes Write/Read/Measure. `STATE_VERSION = 192`. LZ4 compression (legacy LZO parseable). Async pipeline: CPU thread fills buffer → `WorkQueueThread` compresses/writes; atomic rename; in-memory undo buffer.
- **[CONFIRMED]** **Loading savestates is disabled during Netplay** — must be unwound for rollback.
- **[CONFIRMED]** GC memory: MEM1 = 24 MB (+16 MB ARAM). Wii adds 64 MB MEM2.
- **[CONFIRMED — headline]** PR #12911 benchmarks (Ryzen 9 5950X): SSBM full savestate **Save ~11.5 ms, Load ~67.5 ms** (load dominated by the PowerPC namespace, ~55–60 ms — not memory copy). Slippi's custom state: **~1 ms**. → Mainline full savestates are 1–2 orders of magnitude too slow for a 16.6 ms frame budget.
- **[CONFIRMED]** No incremental/dirty-page support merged. Draft PR **#12911** "Track dirty pages…" (WhiteTPoison, draft since July 2024, refs #10873) is explicitly aimed at emulator-level rollback; reviewer constraint (JosJuice): delta savestates must be opt-in, never default.
- **[CONFIRMED]** `github.com/FaultyPine/incremental-rollback`: dirty-page rewinding for Dolphin (Brawl/Project+) using Windows **`GetWriteWatch`** over ~170 MB of game memory; ~1,500 pages dirtied/frame in 1v1; **~1 ms per frame delta save**; 7-frame rollback ≈ **~16 ms total** (~3 ms rollback + ~1 ms/frame resim + ~1 ms/frame delta). **This is our template.**

## 2. Netplay architecture (`NetPlayClient.cpp` / `NetPlayServer.cpp` / `NetPlayProto.h`)

- **[CONFIRMED]** Delay-based; "Fair Input Delay" default. Pad polls serialized as `GCPadStatus` per frame, server relays/orders.
- **[CONFIRMED]** Traversal server = NAT hole-punch only; gameplay is pure P2P afterward (`TraversalClient`); direct host:port also supported.
- **[CONFIRMED]** Desync causes: mismatched ISO/region/version/cheats/graphics hacks/savestates; JIT nondeterminism across CPU arches (AArch64 vs x86-64); Wii-remote config (N/A for MKDD).
- **[CONFIRMED]** `SyncSaveData` syncs memory cards; identical game data required.

## 3. Broadband Adapter emulation (context only — not our netcode layer)

- **[CONFIRMED]** SP1 modes: TAP (driver/admin); **XLink Kai** (PR #8853; proven MKDD-over-internet path, client v7.4.37+); tapserver (PSO servers); HLE/built-in; **Broadband Adapter (IPC)** (PR #13870, merged 2025-10-28, cristian64) — shared-memory frame transport between same-machine instances, auto-discovery, **local only**; useful for dev/testing.
- **[INFERENCE]** BBA gets connectivity, not rollback; the game's LAN mode stays lockstep-limited. Rollback must sit at the emulator input layer.

## 4. Fork maintenance reality

- **[CONFIRMED]** Slippi's Ishiiruka base (fork-of-fork on very old Dolphin) cost "over 3 years" to migrate to mainline (`project-slippi/dolphin` v4.0.0-mainline-beta.1, 2023-10-18; netplay-only beta).
- **[INFERENCE]** Start on current mainline; keep delta small/patch-shaped; isolate rollback behind interfaces; rebase often; upstream generic pieces (opt-in dirty-page savestates à la #12911).

## 5. Performance context

- **[CONFIRMED]** Dolphin is single-thread-bound for game logic (~3 threads total: CPU/GPU/DSP). MKDD is a light GC title (full speed even on weak hardware per RetroArch docs).
- **[UNVERIFIED — measure in Phase 0]** Uncapped MKDD multiplier on target CPU. Per-frame emu cost estimate: Melee ~1 ms, Brawl ~3–4 ms (incremental-rollback data) → MKDD plausibly ~1–3 ms/frame.
- **[INFERENCE]** N-frame rollback ≈ restore + N × (resim + delta save) → 7 frames ≈ 10–20 ms. Near frame budget; hinges on fast restore and cheap resim.
- **[CONFIRMED]** RetroArch's Dolphin core: savestates/rewind yes, netplay no, runahead not supported — no shortcut there.

## Roadmap takeaways

1. Don't build on full savestates (11–67 ms/op); build dirty-page deltas (~1 ms) per incremental-rollback / PR #12911.
2. Rollback at input/emulation layer; BBA/XLink only for testing or legacy connectivity.
3. Current mainline base, minimal delta, rebase-friendly.
4. Determinism: pin JIT arch/settings across peers.
5. **First benchmark**: uncapped single-core MKDD speed + per-frame cost + savestate load profile (JIT/icache cost) on target hardware.

## Sources

- https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/Core/State.cpp · Memmap.h
- https://github.com/dolphin-emu/dolphin/pull/12911 (dirty pages, benchmarks) · #10873 · #13870 (BBA IPC) · #8853 (XLink Kai) · #8754 (UDP BBA, closed)
- https://github.com/FaultyPine/incremental-rollback
- https://github.com/project-slippi/dolphin/releases/tag/v4.0.0-mainline-beta.1
- https://dolphin-emu.org/docs/guides/netplay-guide/ · performance-guide · FAQ
- https://medium.com/project-slippi/fighting-desyncs-in-melee-replays-370a830bf88b
- https://docs.libretro.com/library/dolphin/

## Gaps to close

(a) exact mainline commit Slippi rebased onto; (b) precise `GCPadStatus` wire format (read NetPlayProto.h); (c) benchmark MKDD on target hardware; (d) verify MKDD stays within MEM1/ARAM (delta size).
