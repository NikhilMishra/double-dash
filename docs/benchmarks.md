# Phase 0 Benchmarks (go/no-go gate)

Status: **blocked on build prerequisites** (see README / project log). Numbers to collect on
the target machine once the fork builds:

| Benchmark | Target | Result | Notes |
|---|---|---|---|
| Uncapped MKDD speed (single core), 2P race | ≥ ~500% (≤ ~3 ms/frame) | — | framelimit off, profile CPU thread |
| Per-frame emulation cost (ms) | ≤ ~3 ms | — | derived from above |
| Full savestate save (baseline) | (info only) | — | mainline `State::SaveToBuffer` |
| Full savestate load (baseline) | (info only) | — | profile PowerPC/JIT portion |
| Dirty pages/frame, 2P race | (info) ~1-2k expected | — | `MEM_WRITE_WATCH` + `GetWriteWatch` |
| Dirty-page delta save | ≤ ~2 ms | — | copy dirtied pages + non-RAM state |
| Restore + 7-frame resim | ≤ ~33 ms (2 frame budgets) | — | JIT-cache-preserving restore |

**Gate**: dirty-page save ≤ ~2 ms AND restore+7-frame resim ≤ ~2 frame budgets.
Fallback if failed: Slippi-style targeted region map for MKDD (needs memory-map RE).

Reference numbers from research (other games/machines):
- PR #12911 (5950X, SSBM): full save ~11.5 ms, full load ~67.5 ms (PowerPC namespace ~55–60 ms).
- FaultyPine/incremental-rollback (Brawl): ~1,500 dirty pages/frame, ~1 ms delta save,
  7-frame rollback ~16 ms total.
- Slippi custom savestate (Melee): ~1 ms save+load.
