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

### Results (v2, coalesced + dedup) — idle machine

> **Measurement hazard, learned the hard way.** The first run of these benchmarks was taken
> while antivirus was scanning the drive in the background. Every number came out ~2.5–3x
> pessimistic (snapshot 2.53 ms instead of 0.92 ms; bulk memcpy 3.6 GiB/s instead of
> 10.6 GiB/s). Same binary, same dirty-page count. **Always re-run these on an idle machine
> before trusting them.** The table below is the clean run.

| dirty target | actual pages | GetWriteWatch (mean) | snapshot/frame (mean / p99) | unique pages in 7-frame window | restore 7 frames (mean / p99) |
|---|---|---|---|---|---|
| 500 | 431 | 0.11 ms | **0.44** / 1.00 ms | 1641 | 2.55 / 4.01 ms |
| 1500 | 1008 | 0.16 ms | **0.92** / 1.56 ms | 2820 | 4.24 / 5.33 ms |
| 3000 | 1516 | 0.20 ms | **1.42** / 2.46 ms | 3985 | 5.95 / 7.03 ms |
| 6000 | 2129 | 0.21 ms | **2.20** / 3.46 ms | 5237 | 8.12 / 9.75 ms |
| 10000 | 2743 | 0.25 ms | **2.97** / 5.48 ms | 5860 | 9.11 / 12.17 ms |

(v1, which used per-page 4 KiB memcpys over a uniform random scatter, was ~1.6x slower on
snapshot and ~3x slower on restore. The optimizations above are not optional.)

### Machine memory ceiling (idle)

| copy size | time | rate |
|---|---|---|
| 1 MiB (in-cache) | 0.029 ms | 33.1 GiB/s |
| 4 MiB | 0.124 ms | 31.5 GiB/s |
| 16 MiB | 1.527 ms | 10.2 GiB/s |
| 40 MiB (cold) | 3.686 ms | 10.6 GiB/s |

~10.6 GiB/s is a normal single-core cold-copy figure for this CPU (a single core cannot
saturate dual-channel DDR4; RAM is correctly installed in ChannelA + ChannelB).

### The cost model this gives us

Snapshot cost is almost purely memory bandwidth, and it falls out exactly:

```
snapshot_ms ≈ 0.15 (GetWriteWatch scan) + dirty_pages × 0.75 µs
```

0.75 µs/page is precisely 8 KiB of traffic (4 KiB into the delta + 4 KiB refreshing the
shadow) at 10.6 GiB/s. **Two copies per dirty page is the floor for this scheme** — the
alternatives (post-frame deltas with an incrementally-updated base; copy-on-write via a fault
handler) each cost the same or more. Non-temporal stores should cut the destination
read-for-ownership traffic and buy an estimated 1.3–1.5x; that is the main remaining
optimization, and it is no longer urgent.

**This lands us at parity with Slippi's ~1 ms savestate** at a Brawl-like ~1000 dirty
pages/frame — which is the number Fizzi needed seven months of Melee reverse engineering to
reach. We get it generically.

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
the table (assuming `cpu_emu ≈ 2 ms`, still to be measured):

| MKDD dirty pages/frame | snapshot | per-frame cost at D=2 (≈50 ms RTT) | at D=4 (≈100 ms RTT) |
|---|---|---|---|
| ~500 | 0.44 ms | ~9 ms ✅ | ~15 ms ✅ |
| ~1000 (Brawl-like) | 0.92 ms | ~13 ms ✅ | ~19 ms ⚠️ |
| ~1500 | 1.42 ms | ~16 ms ⚠️ | ~23 ms ❌ |
| ~2000+ | 2.20 ms | ~20 ms ❌ | ~29 ms ❌ |

For calibration, `FaultyPine/incremental-rollback` measured ~1500 dirty pages/frame for Brawl.
MKDD is a lighter game, so ~500–1500 is the plausible range. **At the likely dirty count this
comes in around 1 ms — parity with Slippi's hand-reverse-engineered savestate, achieved
generically. The mechanism is viable and this is worth building.** Same-region play (D ≤ 2) has
real headroom; transcontinental play (D ≥ 4) will need the mitigations below.

Mitigations, in order of cheapness: exclude ARAM (16 MiB of mostly audio — rolling back audio
is unnecessary, and it shrinks the GetWriteWatch scan too); non-temporal stores (est. 1.3–1.5x);
raise input delay to shrink D; exclude known-static regions once we have a memory map.

## Part 2 — In-Dolphin measurement (mechanism validated; full-race number pending)

The `rollback/tracked-arena` fork boots MKDD (verified-clean Redump dump, GM4E01) with
`Config::MAIN_ROLLBACK_TRACK_MEMORY = True`. This is simultaneously the correctness test for the
tracked arena and the first real dirty-page measurement.

### Result: the arena surgery works on a live game

The game boots, compiles shaders, and runs. **No panic, no desync, no MapInMemoryRegion guard
hit, no fastmem failure** — so private write-watched memory with the fastmem arena off and
page-table fastmem on is a working configuration for a real game, not just the unit test.

Arena is one write-watched block of 16448 pages (67 MB): 8192 (MEM1, 24 MB → next-pow2 32 MB) +
64 (L1 cache) + 8192 (fake VMEM). A single GetWriteWatch() covers all of it.

### Dirty pages/frame — attract-mode demo racing (~90 s run)

| window | mean | min | max | est. snapshot @ mean |
|---|---|---|---|---|
| 600 frames | 229 | 6 | 16448 | 0.16 ms |
| 1200 | 257 | 6 | 16448 | 0.19 ms |
| 1800 | 274 | 6 | 16448 | 0.20 ms |
| 2400 | 283 | 6 | 16448 | 0.20 ms |

- **mean ~230–283 pages/frame → ~0.2 ms snapshot**, an order of magnitude under the 16.67 ms
  frame budget and well under the ~1000 (Slippi-parity) mark. Strongly positive.
- **min 6**: idle menu/title frames.
- **max 16448 = the entire arena**: this is the one-time boot `Memory::Clear()` memset, not a
  per-frame gameplay cost (identical across every window because the stat is cumulative; a real
  per-frame spike would move it). Design note: a track *load* also writes large regions, so
  loads must never sit inside a rollback window — they don't, since rollback only spans a race.

### Important caveat: this is attract mode, not a live 2-player race

MKDD's attract loop *is* real race simulation (CPU karts driving actual tracks), so ~280 is a
representative gameplay figure — but a full 2-human race with items, 8 racers, and traffic-heavy
tracks will be somewhat higher. The order of magnitude (few hundred pages) makes it very likely
to stay comfortable, but the **definitive number needs an actual race**, which requires gameplay
input (a human playing, or a TAS input movie). Reproduce with:

```
Dolphin.exe -b -e "<mkdd>.rvz" -u <userdir>
# userdir/Config/Dolphin.ini : [Core] RollbackTrackMemory = True
# userdir/Config/Logger.ini  : [Options] Verbosity=4, WriteToFile=True ; [Logs] MI = True
# read userdir/Logs/dolphin.log
```

### Live 2-player race (human-played, ~90 s)

Reconstructed per-window rate (the logged cumulative mean understates the in-race figure):

| phase | dirty pages/frame | snapshot @ mean |
|---|---|---|
| menus / title | ~230 | ~0.2 ms |
| attract demo | ~305–360 | ~0.25 ms |
| **live race (heaviest window)** | **~640–860** | **~0.6 ms** |

**In-race snapshot cost ≈ 0.6 ms** — around Slippi-parity, well under the 16.67 ms budget. The
snapshot-size question is settled and favorable.

### DECISIVE: the fastmem-arena cost sinks the dirty-tracking approach

The live race exposed a large framerate drop, so speed was measured directly (uncapped, same
attract scene, `tools/bench/` heartbeat that logs emulated fps in either config):

| config | median | floor (heavy scenes) | vs stock |
|---|---|---|---|
| untracked (fastmem arena ON, stock) | **241 fps (~400%)** | never below ~95 fps | 100% |
| tracked (fastmem arena OFF) | **32 fps (~53%)** | ~31 fps | ~1/7 |

**Disabling the fastmem arena — which `MEM_WRITE_WATCH` requires — costs ~7× emulation speed and
drops MKDD below realtime.** The dirty-tracking approach therefore trades a ~0.6 ms snapshot
saving for a penalty that breaks realtime *before* rollback resim is even added. It is not
viable as built. **Phase 1 pivots to full-memory-copy snapshots, which keep the fastmem arena on
(see `docs/design.md`).** The `DirtyPageTracker` / tracked arena stay in the tree as a
measurement tool and a possible future Linux path (soft-dirty tracks aliased memory without
disabling fastmem).

Full-copy sanity check: MEM1 real size is 24 MiB → ~2.2 ms/frame at 10.6 GiB/s. With ~400% stock
speed headroom (~4 ms to emulate a frame), 4 + 2.2 = ~6.2 ms/frame — comfortably under 16.67 ms,
and rollback resim runs at full fastmem speed.

### Still to measure (Phase 1)

| Benchmark | Why it matters | Status |
|---|---|---|
| Full MEM1-copy snapshot cost, in-emulator | the new approach's real per-frame tax | pending |
| Restore + N-frame resim wall cost at full fastmem speed | whether a rollback burst fits | pending |
| Full savestate save/load baseline | confirms mainline's path is unusable (expect ~11/~67 ms) | pending |

### Prerequisites (all resolved 2026-07-14)

Disk (9.3 → 64.7 GB), VS2022 C++ workload (MSVC 14.44), Windows 11 SDK 10.0.26100, CMake 4.4.0
(glslang builds through it), gh 2.96. Fork at github.com/NikhilMishra/dolphin.
