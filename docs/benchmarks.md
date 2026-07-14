# Phase 0 Benchmarks

## Test machine

Intel Core i9-9900KF (8C/16T, 3.6 GHz), 32 GB DDR4-3200 dual-channel (verified:
ChannelA-DIMM1 + ChannelB-DIMM1), Windows 10 Home 19045.

## Part 1 — Dirty-page snapshot mechanism (DONE, standalone)

The biggest risk in the plan was whether `GetWriteWatch` dirty-page snapshotting is fast
enough to snapshot every frame and restore inside a 16.67 ms budget. That is measurable
**without Dolphin**, so it was measured first: `tools/bench/writewatch_bench2.cpp` models the
GameCube arena (MEM1 24 MiB + ARAM 16 MiB), dirties N pages/frame in a realistic pattern
(75% inside a 4 MiB hot region, arriving in short contiguous runs), and times the exact
snapshot/restore path a real implementation would run.

Snapshot design measured: a shadow copy tracks live memory as of the last frame; each frame
`GetWriteWatch(RESET)` yields dirty pages; their **pre-frame** contents (still in the shadow)
become that frame's undo delta, then the shadow refreshes from live memory. Rolling back =
replaying deltas in reverse. Two optimizations matter a lot and are in the measured numbers:
**coalescing contiguous dirty pages into single memcpys**, and **de-duplicating pages across
the restore window** (walk deltas oldest-first; the first writer of a page wins, later frames
skip it — the hot working set is re-dirtied every frame, so this collapses ~7x of work).

### Results (v2, coalesced + dedup)

| dirty target | actual pages | GetWriteWatch (mean) | snapshot/frame (mean / p99) | unique pages in 7-frame window | restore 7 frames (mean / p99) |
|---|---|---|---|---|---|
| 500 | 431 | 0.18 ms | **1.03** / 1.72 ms | 1641 | 4.66 / 5.91 ms |
| 1500 | 1008 | 0.31 ms | **2.53** / 3.50 ms | 2820 | 8.00 / 9.84 ms |
| 3000 | 1516 | 0.35 ms | **3.12** / 4.64 ms | 3985 | 9.53 / 13.19 ms |
| 6000 | 2129 | 0.33 ms | **3.70** / 6.40 ms | 5237 | 11.05 / 17.18 ms |
| 10000 | 2743 | 0.55 ms | **6.85** / 8.62 ms | 5860 | 16.72 / 19.28 ms |

(v1, which used per-page 4 KiB memcpys over a uniform random scatter, was ~1.6x slower on
snapshot and ~3x slower on restore. The optimizations above are not optional.)

### Machine memory ceiling

| copy size | time | rate |
|---|---|---|
| 1 MiB (in-cache) | 0.036 ms | 27.1 GiB/s |
| 4 MiB | 0.736 ms | 5.3 GiB/s |
| 16 MiB | 4.067 ms | 3.8 GiB/s |
| 40 MiB (cold) | 10.728 ms | 3.6 GiB/s |

RAM is correctly dual-channel; ~3.6 GiB/s is just this CPU's **single-core** cold-copy limit
(a single core cannot saturate dual-channel DDR4; the ~120 MB of actual DRAM traffic per
40 MiB copy — read source, read-for-ownership on destination, write destination — works out
to ~11 GB/s, which is a normal single-core figure).

### The cost model this gives us

Snapshot cost is almost purely memory bandwidth, and it falls out exactly:

```
snapshot_ms ≈ 0.3 (GetWriteWatch scan) + dirty_pages × 2.2 µs
```

2.2 µs/page is precisely 8 KiB of traffic (4 KiB into the delta + 4 KiB refreshing the
shadow) at 3.6 GiB/s. **Two copies per dirty page is the floor for this scheme** — the
alternatives (post-frame deltas with an incrementally-updated base; copy-on-write via a fault
handler) each cost the same or more. Non-temporal stores should cut the destination
read-for-ownership traffic and buy an estimated 1.3–1.5x; that is the main remaining
optimization.

### What this means for the rollback budget

Rollback re-simulates without rendering, so a re-simulated frame costs CPU-only emulation plus
another snapshot. Steady state, per displayed frame:

```
per_frame = (D + 1) × (cpu_emu + snapshot) + restore(D)      D = rollback depth in frames
D ≈ max(0, one_way_latency_in_frames − input_delay_frames)
```

Budget is 16.67 ms. With input delay 2 (Slippi's default), a friend at 30–60 ms RTT gives
D ≈ 1–2; at 100 ms RTT, D ≈ 4. So feasibility hinges on `(cpu_emu + snapshot)` being small —
which makes **MKDD's actual dirty-pages-per-frame the single decisive unknown.** Read it off
the table:

- If MKDD dirties **~500 pages/frame** → snapshot ~1.0 ms → comfortable at D ≤ 4.
- If **~1500** → snapshot ~2.5 ms → workable at D ≤ 2 (same-region friends), tight beyond.
- If **~3000+** → snapshot ≥ 3.1 ms → needs mitigation (see below).

For calibration, `FaultyPine/incremental-rollback` measured ~1500 dirty pages/frame for Brawl.
MKDD is a lighter game than Brawl, so ~500–1500 is the plausible range — i.e. **the mechanism
looks viable, and this is worth building.** But it is not yet proven for MKDD.

Mitigations held in reserve if the dirty count comes in high: exclude ARAM (16 MiB of mostly
audio — rolling back audio is unnecessary); non-temporal stores; raise input delay to shrink
D; exclude known-static regions once we have a memory map.

## Part 2 — In-Dolphin measurements (BLOCKED)

These require the fork to build and cannot be faked standalone:

| Benchmark | Why it matters | Status |
|---|---|---|
| MKDD dirty pages/frame, 2P race | **The decisive unknown** — indexes into the table above | blocked |
| MKDD CPU-only frame cost (no render) | the other half of `(cpu_emu + snapshot)` | blocked |
| Full savestate save/load baseline | confirms mainline's path is unusable (expect ~11/~67 ms) | blocked |
| JIT-cache-preserving restore | mainline's savestate *load* is dominated by the PowerPC namespace | blocked |

**Blocked on build prerequisites** (need user action — see project README / final report):
1. **Disk**: 9.3 GB free on C:. Need ~30 GB (VS2022 C++ workload ~10 GB, Dolphin source +
   submodules ~2 GB, build artifacts ~10 GB).
2. **VS2022 C++ workload is not installed.** VS2022 17.14 is present but has no MSVC toolset;
   the only C++ compiler on this machine is VS2019's MSVC 14.24 (used for the benchmarks
   above). Dolphin mainline requires VS2022 + C++20.
3. **Windows 11 SDK.** Newest installed is 10.0.18362 (Win10 1903); Dolphin needs 10.0.22621+.

Nice-to-have: `gh` CLI (absent) for forking; git is 2.29 (old but workable).
