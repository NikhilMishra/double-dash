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

## Part 3 — Phase 1: rollback core proven deterministic

Built `Core/Rollback/RollbackState`: fast full-machine capture/restore reusing Dolphin's
`SaveToBuffer`/`LoadFromBuffer` (no compression, no disk) with the JIT cache clear skipped on
restore (`JitInterface::DoState` now honors `Rollback::ShouldSkipJitCacheClear`). A self-test
(`MAIN_ROLLBACK_STATE_SELFTEST`, single-core) exploits attract-mode determinism: capture at frame
F, run K=7 frames, roll back, re-run 7 frames, and compare **guest MEM1** (the netplay-relevant
state — not the video/audio host caches).

**Result: restore-to-anchor is byte-perfect, every single iteration (0 mismatches in 500+).**
The snapshot captures and restores the whole machine faithfully, and skipping the JIT clear is
safe for same-session rollback. This is the core correctness proof the whole approach depended on.

Replay determinism took longer to pin down and is written up in "The intermittent-divergence
hunt" below — the short version is that re-running K frames reproduces guest MEM1 exactly except
for a **bounded, non-cascading handful of bytes (~5% of iterations)** in two fixed host-timed
scratch buffers that the simulation never reads back. The game logic is deterministic; those
bytes are cosmetic. (An earlier "PASS every iteration" claim here was from too few samples — 12
all-pass runs is ~50/50 luck at a 5% rate. Corrected below.)

Measured cost (i9-9900KF, fastmem arena ON):

| op | typical | notes |
|---|---|---|
| capture (full machine) | ~8–10 ms | vs Dolphin's ~11.5 ms compressed save |
| restore + resim skipping JIT clear | ~10–18 ms | vs the ~67 ms load we were avoiding |
| snapshot size | **90 MB** | MEM1 24 + fake-VMEM 32 + video/audio/HW — fat |

The JIT-clear skip works: restore is ~10 ms, not ~67 ms. But the 90 MB snapshot (Dolphin's full
`DoState`, not just MEM1) makes per-frame capture ~8 ms — too heavy once resim has to re-capture
each frame. **Next: trim the snapshot toward MEM1 + CPU + essential HW (~24 MB → ~2 ms capture),
re-running the determinism test after each trim to find the minimal deterministic set.**

Determinism note: the first self-test version compared the entire 90 MB snapshot and FAILED —
because Dolphin's video `DoState` serializes host-side caches and even writes EFB back to RAM
during capture. Comparing guest MEM1 only is both correct (that's what must replay identically)
and what exposed the truth.

### The intermittent-divergence hunt (resolved — core is sound)

Hashing guest MEM1 over many more iterations exposed an **intermittent ~5% replay mismatch**:
restore-to-anchor was always OK, but re-running K frames occasionally produced a guest-MEM1 hash
different from the straight run. A 5%-per-7-frames desync would make rollback unusable, so this
had to be root-caused before building the loop. Each suspect got a config toggle and an A/B run
of ~90–115 iterations (single-core, uncapped, idle machine):

| Config changed | Failure rate | Verdict |
|---|---|---|
| Snapshot trim on → **off** (full 90 MB) | 2/40 (~5%) | trim exonerated |
| DSP thread on → **off** (synchronous DSP) | 4/92 (~4%) | DSP thread exonerated |
| JIT-clear skip on → **off** (force clear) | 4/95 (~4%) | fast-restore skip exonerated |
| GPU backend → **Null** (no host GPU) | 4/96 (~4%) | host GPU exonerated |

The rate is flat ~4–5% across every configuration, and **restore-to-anchor never once failed
(0 mismatches across 500+ iterations)**. So the divergence is not in the snapshot, the DSP
thread, the JIT-clear trick, or the GPU — it is a small forward-execution nondeterminism present
even with no host GPU and a single CPU core.

Localizing it (log first/last differing offset + byte count on each FAIL) was decisive:

- The diff is **1–61 scattered bytes** over a ~1 MB span (**0.0% density** — not a framebuffer
  block, which would be dense and contiguous).
- It clusters at **two fixed guest addresses: ~0x8037_611f and ~0x8048_c3xx**, iteration after
  iteration. One failure was a **single byte**.
- **It does not cascade.** Re-running the replay horizon at **K=40 frames** (≈6× longer) kept the
  diff at 1–61 bytes — same magnitude, same addresses. A real simulation desync (kart physics,
  positions, RNG) would explode to thousands/millions of bytes within 40 frames as every float
  diverged. It stays a handful.

**Conclusion: the rollback core is correct and the MKDD simulation is deterministic.** The
mismatch is confined to two fixed host-timed *leaf* buffers (almost certainly audio/DTK streaming
scratch — MKDD's attract mode streams music) that are written but never read back into game logic,
so they cannot cause a gameplay desync. This is consistent with the external fact that **Dolphin's
own netplay plays MKDD without desyncs** — impossible if the CPU simulation were 5% nondeterministic.

Consequence for the design: rollback re-simulation reproduces game logic exactly; those leaf bytes
may differ but never feed the sim, so no desync. The eventual peer-to-peer **desync-detection hash
must cover game-logic RAM and exclude these host-timed scratch regions** (or peers will false-alarm
on cosmetic bytes). Identifying the exact owning subsystem of 0x8037_611f is a documented follow-up,
not a blocker. Toggles added for this hunt (`RollbackTrimSnapshot`, `RollbackSkipJitClear`,
`RollbackSelfTestFrames`) stay in the tree as diagnostics.

### Still to measure (Phase 1)

| Benchmark | Why it matters | Status |
|---|---|---|
| Replay determinism root-cause | must be sound before the loop | **done — core correct (above)** |
| Trimmed snapshot determinism | proves the fake-VMEM cut is safe | **done — trim behaves identically to full** |
| Trimmed snapshot cost | get per-frame capture toward ~2 ms | next (MEM1+CPU+HW, drop more regions) |
| Full rollback loop under simulated RTT | the Phase 1 gate | pending |
| Full savestate save/load baseline | confirms mainline's path is unusable (~11/~67 ms) | pending |

### Prerequisites (all resolved 2026-07-14)

Disk (9.3 → 64.7 GB), VS2022 C++ workload (MSVC 14.44), Windows 11 SDK 10.0.26100, CMake 4.4.0
(glslang builds through it), gh 2.96. Fork at github.com/NikhilMishra/dolphin.

## Part 4 — Snapshot capture cost: it is pure copy bandwidth, and the copy is already optimal

Goal this session: drive the trimmed full-copy snapshot toward Part 3's ~2 ms open item. Result:
the target is not reachable by changing *how* we copy — only by copying *fewer bytes*.

### Where the capture time goes (per-device breakdown, live MKDD, trim on)

Instrumented `State::DoState` per section and `HW::DoState` per device during live per-frame
capture (`RollbackDriveFrames`+`RollbackLocalTest`, single-core, ~2400 frames of attract mode):

| section | ms |
|---|---|
| video backend (host caches, EFB→RAM) | 2.6 |
| **HW total** | **5.5** |
| &nbsp;&nbsp;— MEM1 (24 MiB copy) | 3.7 |
| &nbsp;&nbsp;— DSP / ARAM (16 MiB copy) | 1.8 |
| &nbsp;&nbsp;— all 9 other HW devices combined | ~0.01 |
| CoreTiming + PowerPC | ~0.01 |
| **total capture** | **~8.2 ms** |

The HW cost is **entirely the two big memcpys** (MEM1 + ARAM = 40 MiB). Every other device is
noise; there is no hidden serialization or per-device overhead to remove. (An earlier reading put
`hw` at ~11.4 ms and video at ~5.6 ms; the *same build* later measured 5.5 / 2.6. Both halves
scale together ~2×, i.e. CPU-frequency / memory-contention state, not code. ~8 ms is the
representative steady figure, demo races included.)

### The copy is already at the bandwidth wall — method does not matter

Tried non-temporal (streaming) stores to skip the destination read-for-ownership traffic (Part 0
predicted a 1.3–1.5× win). Isolated 40 MiB cold-copy microbench (`tools/bench/copybench.cpp`,
median of 40 iters, 8 cold destination buffers):

| strategy | threads | ms | GB/s |
|---|---|---|---|
| memcpy | 1 | 2.71 | 15.5 |
| memcpy | 4 | 2.63 | 15.9 |
| stream (NT) | 1 | 2.97 | 14.1 |
| stream (NT) | 8 | 2.85 | 14.7 |

**Plain `memcpy` is already optimal here and NT stores are marginally *slower*.** MSVC's `memcpy`
uses ERMSB (`rep movsb`), which already avoids the write-allocate read on large copies, so there
was no RFO traffic left to remove; threading doesn't help either (one core saturates the effective
~15 GB/s). **The streaming-store change (`Common/StreamingMemcpy.h`, a `ChunkFile.h` fast path) was
implemented, measured, and reverted.** Part 0's NT estimate was for a hand-rolled per-page copy
that never hit ERMSB; it does not apply to the bulk `DoArray` memcpy. (In-emulator the copy runs
~6–9 GB/s, roughly half the isolated rate, from GPU-thread memory contention — which NT stores also
cannot fix.)

### What this means for the loop — input delay, not copy speed, is the lever

Because rollback re-simulation **re-captures every re-simmed frame**, per displayed frame at
rollback depth D (capture ≈ restore ≈ 8 ms, `cpu_emu` ≈ 4 ms):

```
per_frame ≈ (D+1)(cpu_emu + capture) + restore(D)
```

| D | per-frame (on rollback frames) | fps | verdict |
|---|---|---|---|
| 0 | 12 ms | ~83 | ✅ |
| 1 | 32 ms | ~31 | ⚠️ occasional 1-frame hitch |
| 2 | 44 ms | ~23 | ❌ |

**Full-copy at 8 ms is fine at D=0, marginal at D=1, too slow at D≥2.** The `(D+1)×capture`
multiplier is the whole problem — which is exactly why a cheap snapshot matters. Two levers keep D
low; only one is cheap now:

- **Input delay (cheap, MKDD-friendly).** D ≈ max(0, one-way-latency-frames − input-delay). MKDD is
  a kart racer, not a fighter — 3–4 frames of input delay is imperceptible here and drives D→0 for
  same-region play (RTT ≲ 50 ms). That alone makes the 8 ms full-copy snapshot viable *for MKDD*.
- **Curated-region snapshots (Slippi-style, deferred).** Part 2 measured only ~280–860 pages
  (~1–3.5 MiB) actually changing per frame; copy just the game-state regions via a static allowlist
  (no page protection → fastmem stays on) for a ~1 ms snapshot that is robust at any depth. Needs a
  reverse-engineered MKDD memory map; not built until the playable test proves it necessary.

**Decision: proceed to the playable test with full-copy snapshots + generous input delay, and
measure real 2-player rollback frequency/depth before spending RE effort on curated regions.** The
copy cannot be made faster; only copying fewer bytes would help, and whether that is needed is an
empirical question the playable test answers.

### Reproduce (measurement harness, learned this session)

The runnable exe is `Binary/x64/Dolphin.exe` (deployed with its Qt DLLs) — **not**
`Build/x64/Release/Dolphin/bin/Dolphin.exe` (bare linker output, missing Qt6Core.dll). Launch with
config forced via `-C` (a `-u` user-dir ini was not reliably applied), and **quote the game path as
a single argument** — PowerShell 5.1 `Start-Process -ArgumentList @(...)` splits it at the first
space, so Dolphin silently boots nothing:

```
Dolphin.exe -u <userdir> -b `
  -C Dolphin.Core.CPUThread=False `
  -C Dolphin.Core.RollbackDriveFrames=True -C Dolphin.Core.RollbackLocalTest=True `
  -C Dolphin.Core.RollbackTrimSnapshot=True `
  -e "<path with spaces>.rvz"
# Logger.ini: [Options] Verbosity=4, WriteToFile=True ; [Logs] MI=True
```

## Part 5 — Playable test: MKDD re-simulation must render, so cheap rollback is off the table

Wired the live loop to a playable session (real pad on port 1, fake remote on port 2, live frames
paced by the existing VideoInterface throttle, throttle disabled during resim) and played it. The
result overturns Part 4's optimistic read.

### It stutters on every input — and the copy is not why

Per-op breakdown during a synthetic worst case (a fake remote whose stick changes every field, so a
rollback fires every frame; `RollbackP2Mirror=False`), depth 2:

| op | per-call | note |
|---|---|---|
| snapshot capture | 8 ms | as measured before |
| snapshot restore | 8–10 ms | fine |
| **live field** | **2.8 ms** | a normal frame; GPU work pipelines elsewhere |
| **re-simulated field** | **19–26 ms** | the *same field*, ~9× slower |

A depth-2 rollback lands at **~70–280 ms**, i.e. a hard stutter on every input change. The dominant
cost is **re-rendering the resimmed frames**, not the snapshot copy. (Present-skip — gating
`Video_OutputXFB` on a resim flag — only recovered 26→19 ms; the swap-to-screen was a small part.)

### Decisive experiment: skip the GPU during resim → catastrophic desync

Added `FifoManager::SetSkipDrawForResim` (drains the FIFO in `RunGpuOnCpu` without running
`OpcodeDecoder::RunFifo` — no draws, no EFB→RAM copies) and had the **sync self-test** re-simulate
with it on, comparing the normally-rendered straight run's guest RAM against the GPU-less replay's:

```
sync self-test: restore + 7-field resim | restore-to-anchor OK, replay determinism *** FAIL ***
divergence: first 0x000000c2, last 0x016cf63f, span 23357 KiB, differing 1442202 bytes (6.03%)
```

**Every cycle failed, diverging ~80 K–1.4 M bytes cascading across nearly all of MEM1** — not the
1–61-byte cosmetic audio scratch from Part 3, but the whole simulation coming apart. **MKDD reads GPU
output (EFB→RAM copies and/or GPU sync tokens) back into game logic, so re-simulation cannot skip the
GPU.** This is the structural difference from Melee, where Slippi *can* skip rendering during
rollback. The GPU-skip was reverted (kept only the RAM-safe present-skip).

### Consequence: no cheap rollback for MKDD

Every resimmed frame must run a full MKDD render (~16–18 ms single-core). That cost scales with
rollback depth and nothing removes it:

- **Curated-region snapshots don't rescue it** — they shrink the copy (~8→~1 ms) but not the render,
  which is the dominant term. The Part 4 plan to shrink snapshots is necessary-but-insufficient.
- **Dual-core doesn't help** — resim needs the GPU's RAM output synchronously, so the GPU thread must
  be waited on each resimmed frame anyway.

So the Slippi model (skip render + curated regions) does **not** port to MKDD; the render-skip half
is blocked by MKDD's CPU↔GPU coupling.

### Where this leaves the netcode: delay + rollback hybrid

Rollback can't be the *constant* mechanism for MKDD, but it's still valuable as a **safety net over
input-delay netcode**:

- Input delay ~3–4 frames (≈50–67 ms, imperceptible for a kart racer) hides the *typical* latency, so
  for same-region friends rollback depth is ~0 almost always — smooth, no resim.
- Rollback keeps the two consoles perfectly in sync (MKDD's real weakness online is desyncs) and
  absorbs the *occasional* late packet without padding the fixed delay for the worst case. Those
  rollbacks are rare and shallow, so the brief hitch is acceptable.

This is desync-free and low-latency for close friends, degrading gracefully with distance — a real
improvement over MKDD's existing online, just not zero-delay rollback. **Next: add input delay to the
harness (the `Match` has `sim_latency` = a depth knob but no input delay yet) and validate the smooth
case, before any networking.** The alternative that preserves constant rollback — reverse-engineer
exactly which EFB/GPU results MKDD reads and reproduce just those during resim without a full render —
is months of uncertain work and is not recommended unless the hybrid proves inadequate.

## Part 6 — Delay+rollback hybrid: the smooth case is real (0 rollbacks, locked 60 fps)

Built the hybrid Part 5 recommended. The harness now has an **input-delay line** (config
`RollbackInputDelay`, default 3): the controller read on field *f* is applied to game-field
*f + input_delay*. The fake remote applies the same delay, so its value is *for* field
*f + input_delay* and reaches us `sim_latency` (+ occasional `sim_jitter`) fields after it was
produced. The effective rollback depth is therefore **D = max(0, sim_latency − input_delay)**: when
the delay covers the latency the remote input arrives *before* its frame is simulated, so it's never
predicted and never mispredicted → **no rollback at all**.

### Smooth case, played on real MKDD (input-delay 3, latency 2 → D = 0)

Real Xbox pad on port 0, mirrored to port 1 (`RollbackP2Mirror=True`), no jitter. Steady state over
2 s windows:

| window | fps | rollbacks | worst frame |
|---|---|---|---|
| boot warmup | 57.3 | 0 | 65 ms |
| steady | **59.9** | **0 (0 %)** | **17.1 ms** |

Per-op cost at steady state: capture 6.5 ms + live-step 10.2 ms ≈ 16.7 ms/field = a locked 60 fps.
**Zero rollbacks, zero re-simulations, zero restores** — the 3-field input delay (≈50 ms, imperceptible
for a kart racer) fully absorbs the 2-field latency. This is the exact opposite of the Part 5 stutter:
the resim path simply never runs. Confirms the same-region experience is buttery.

### Safety-net case (input-delay 3, latency 2, jitter 3 every 45 fields → depth-2 rollbacks)

Forced an occasional late packet (`RollbackSimJitter=3`, `RollbackJitterPeriod=45`) against a
churning synthetic remote (`RollbackP2Mirror=False`), so every late packet is a guaranteed
misprediction and rollback fires on a fixed schedule. Effective depth for the late packet =
sim_latency + jitter − input_delay = 2 + 3 − 3 = **2**.

| metric | value | note |
|---|---|---|
| rollbacks | 2–3 / 120 frames (2 %) | ≈120/45, exactly on schedule |
| depth | avg 2.0, max 2 | formula confirmed |
| fps | 54.6–57.9 | down from a locked 60 |
| restore | ~10 ms | once per rollback, depth-independent |
| **resim field** | **25–37 ms each** | the MKDD full re-render (Part 5) |
| **worst frame** | **76–140 ms** | the visible hitch |

**The safety net works but is not free.** Rollback fires precisely when a packet is late, corrects the
misprediction, and holds the two sims in sync — but because MKDD must re-render every resimmed field,
the cost is **≈ 10 + depth × 30 ms**: depth-1 ≈ 40 ms (a mild blip), depth-2 ≈ 70 ms (a visible
hitch), depth-3 ≈ 100 ms. A depth-2 rollback does **not** fit the 16.7 ms budget; it's a ~4-frame
stall. This is the direct consequence of Part 5 (no render-skip for MKDD) applied to the hybrid.

### Design consequence: input delay is the latency-hider; rollback is a *thin* margin (depth ≤ 1)

The hybrid is excellent at D = 0 (smooth) but degrades sharply with depth, so the netcode must keep
depth at 0 almost always and 1 rarely — never rely on rollback to absorb multi-frame latency swings:

- Set input delay to cover latency **plus typical jitter**, so the common packet is D = 0 and only a
  rare worst-of-jitter packet is D = 1. For same-region friends (jitter ≈ ±1 field) that's
  `input_delay ≈ ceil(one-way latency) + 1`.
- When the network worsens, **raise the input delay** (dynamic delay, à la GGPO/Slippi frame-advantage)
  rather than letting rollback depth climb — a few extra ms of delay is imperceptible, a depth-2+
  rollback is a felt stall.
- Rollback's real job here is **desync-proofing** (MKDD's actual online weakness) plus absorbing the
  *occasional* single-frame miss, not being the primary latency mechanism.

The smooth half and the safety-net half are both now measured on real MKDD.

## Part 7 — The re-simulation cost is a per-*restore* warmup, NOT the GPU render (Part 5 was wrong on the mechanism)

Part 5 concluded the resim cost was the GPU re-render and that MKDD therefore can't do cheap rollback.
Chasing "can we make low input delay viable without the stutter," a clean chain of A/B experiments
(constant depth-N rollback via the churn harness, `RollbackP2Mirror=False`, `RollbackInputDelay=0`)
overturned that attribution. All numbers are per-op averages over 240 resim samples/window on real MKDD.

**Experiment 1 — Null video backend.** resim-step is identical with the real backend (~18–27 ms) and
the Null backend (~18–27 ms). Null does zero rasterization, zero EFB→RAM readback, zero GPU sync. So
the cost is **not** the GPU pixel render or readback.

**Experiment 2 — time `OpcodeDecoder::RunFifo` during resim** (added `FifoManager::SetTimeResimFifo`,
non-destructive timing around the single-core GPU-on-CPU RunFifo call). Of a ~20–27 ms resim-step,
**RunFifo is 0.3–0.6 ms**; the other ~20–26 ms is PPC guest-code execution. So the cost is **not** the
CPU-side FIFO/vertex/draw processing either.

**Experiment 3 — depth-1 vs depth-2.** resim-step is logged as an average over the D re-simulated
fields per rollback. Depth-2 averaged ~20 ms; **depth-1 (which measures only the first-post-restore
field) is 36–51 ms.** So the first re-simulated field after a restore costs ~40 ms and every later
field costs ~2 ms (like live). The cost is a **per-restore warmup**, flat in depth:

| | first field after restore | later fields | live field |
|---|---|---|---|
| wall time | **~40 ms** | ~2 ms | ~2 ms |
| of which RunFifo | 0.5 ms | 0.5 ms | — |

**Corrected cost model:** rollback ≈ restore (~8 ms) + **~40 ms warmup** + (depth−1) × ~2 ms. Nearly
flat in depth; dominated by a one-time ~40 ms hit per *restore*. This is why constant rollback (low
input delay + churny input → a rollback every frame) drops to ~12–15 fps: every frame pays the warmup.

**Experiment 4 — fastmem off.** The first-post-restore field is still 37–60 ms with `Fastmem=False`
(vs ~3 ms live), so the warmup is **not** fastmem re-backpatching. It grows slightly with fastmem off —
the signature of executing *more guest instructions*, since the slow path costs more per access.

**Also ruled out:** JIT recompile from a cache clear — `MAIN_ROLLBACK_SKIP_JIT_CLEAR` defaults true and
`JitInterface::DoState` genuinely skips `ClearCache` on restore (restore stays ~8 ms; the block cache is
retained). So the warmup is not a recompile storm.

**Conclusion: the first field after a restore executes ~20× the guest instructions of a live field.**
The leading remaining hypothesis is that the game's idle-wait is **not fast-forwarded** after a restore
the way it is in live play (idle-skip / CoreTiming state), so the first field spins the idle loop for
real. Needs one instrumented run (idled-cycle / guest-instruction count per field, live vs first-resim)
to pin exactly.

**Why this changes the strategy (and is good news for latency):** the rollback cost is per-*restore*,
fixed (~48 ms), and a cold-state artifact — **not** per-render and **not** the inherent GPU cost Part 5
feared. If the first-post-restore field is made as cheap as a live field (~2 ms), a rollback drops from
~48 ms to ~10 ms — cheap enough to absorb frequent shallow rollbacks, which makes **low / zero input
delay viable** (the actual goal) without the months-of-GPU-reverse-engineering path. The Part 6 rule
("input delay primary, depth ≤ 1") holds only *until* the warmup is eliminated; eliminating it is now
the highest-leverage work for latency.

## Part 8 — The per-restore warmup, found and fixed: BAT-remap was clearing the JIT

Instrumented the hunt and landed the fix. The warmup was **not** idle-skip and **not** the arena write:

**Idle-skip ruled out.** Logged CoreTiming `GetTicks`/`GetIdleTicks` per field (executed = ΔTicks −
ΔIdle). Live and first-resim fields have *identical* executed (~311 K cyc) and idled (~7.67 M cyc)
counts — same instructions, same idle-skip — yet the first-resim field takes ~40 ms vs ~2.5 ms. So the
*same* code runs ~20× slower for one field; it's a host-side effect, not more work.

**Arena write ruled out.** Added `RollbackDirtyArenaMB`, which writes N MiB of the guest arena back to
itself (values unchanged) before each *live* field. Writing the full 24 MiB MEM1 left live-step at
~2.5 ms — the arena write does not cause the warmup. (Also: the snapshot *capture* copies ~112 MiB
before every live field and those stay fast, so it isn't cache/bandwidth thrash.) By elimination the
cause is a restore-read-mode *subsystem* side effect, not the memory contents.

**Root cause.** `PowerPCManager::DoState` on load (PowerPC.cpp:111–126) calls `MMU::IBATUpdated()` and
`MMU::DBATUpdated()`, and each ends in `JitInterface::ClearSafe()` → `GetBlockCache()->Clear()`. So
**every rollback restore cleared the JIT block cache** — despite the careful skip in
`JitInterface::DoState` — and the first re-simulated field had to **recompile every hot block**. The
clear is cheap (restore stayed ~8 ms); the deferred recompile is the ~40 ms. This fits every
observation: same instructions (recompiled then run), fastmem-independent, Null-identical, RunFifo ≈ 0,
per-restore/first-field-only, flat in depth.

**Fix (one guard).** `JitInterface::ClearSafe()` now honors `Rollback::ShouldSkipJitCacheClear()` — the
same flag `DoState` already uses. During a rollback the guest returns to an earlier point in the *same*
session, so the restored BAT/PAT config is one whose compiled blocks are still valid; keeping them is
safe. Outside rollback (a real BAT change) the clear still runs.

**Result (real MKDD, churn harness, throttle disabled during resim):**

| metric | before | after |
|---|---|---|
| first-post-restore field | ~40 ms | **~4.5 ms** |
| restore | ~8 ms | ~5.5 ms (no Clear) |
| depth-2 jitter rollback hitch | 76–140 ms | **~52 ms** |
| worst-case 100 %-rollback fps | ~13 | **~29** |

**Determinism preserved:** the sync self-test (restore + 12-field replay, guest-RAM compare) is PASS
every cycle, restore-to-anchor OK, zero divergence — the skip is safe.

**Corrected cost model:** rollback ≈ restore (~6 ms) + ~4.5 ms first field + (depth−1) × ~2 ms. A
depth-1 rollback is now **~10 ms** (was ~48 ms). Low input delay is now viable; the next bottleneck for
*constant* rollback is the snapshot **capture** (~8 ms, ×2 on a rollback frame) — see Part 9.

## Part 9 — Capture cost: curation doesn't work for MKDD; a safe trim gets 8 → 6 ms

Went after the ~8 ms capture (video 2.6 + hw 5.5). Two results.

**Curated-region snapshots are dead for MKDD.** Added cumulative dirty-page *union* tracking to
`DirtyPageTracker` (per-page seen-bitset). The idea was a Slippi-style static allowlist: copy only the
regions that ever change. But over an attract-mode session the **union reaches 100 % of the 16 448-page
(64 MiB) arena within the first 600 frames** — even though the *mean* is only ~280 dirty pages/frame
(~1.1 MiB). Occasional full-memory writes (scene loads / heap resets — the `max 16448` frames) force any
static allowlist to include everything, so it degenerates to the full copy. Per-frame *incremental*
snapshots would be cheap (~0.2 ms) but need the write-watch tracker live, which forces fastmem off (the
Phase 0 ~7× penalty, already rejected). So there is no cheap curated capture on Windows with fastmem on.

**Safe trim landed (8 → 6 ms).** `MemoryManager::DoState` copied `GetRamSize()` = `NextPowerOf2(24 MiB)`
= **32 MiB**, i.e. 8 MiB of dead power-of-two padding above real MEM1 (the game only addresses the low
`GetRamSizeReal()` bytes). Under `Rollback::IsTrimmingSnapshot()` it now copies only 24 MiB. Capture and
restore both trim so the buffer stays consistent; full savestates are unchanged. Measured: hw
**5.5 → 3.7 ms**, total capture **8 → ~6 ms**, sync self-test determinism **PASS**.

| capture component | before | after |
|---|---|---|
| video_backend | 2.4 ms | 2.4 ms |
| hw (MEM1 + ARAM) | 5.5 ms | **3.7 ms** |
| **total** | **~8 ms** | **~6 ms** |

**What's left, and why it's deferred.** The remaining capture is `video_backend` (~2.4 ms — texture
cache + framebuffer, which resim *regenerates*, so possibly trimmable but risky for EFB-readback/visual
correctness) and ARAM (~1.8 ms — audio DMA/mailbox feeds game logic, unsafe to trim wholesale). Neither
is a clean win. Crucially, **after the Part 8 warmup fix, capture is no longer the binding constraint**
for realistic play: the smooth case (D=0) is a locked 60 fps, and only the pathological constant-rollback
case (low delay + churny input, a rollback every frame) is capture-bound — and curation can't fix that.

**Promising future lever (not built): background the capture during the throttle sleep.** In single-core,
the CPU thread is idle during `VideoInterface::Throttle`, so guest memory is static — a snapshot copy
kicked off on a worker thread at the field boundary would be a consistent point-in-time copy and finish
inside the idle window, *hiding* the ~6 ms capture in the smooth case rather than reducing it. Complex
(threading/sync) and single-core-specific; noted for later. **Verdict: capture is good enough post-fix;
proceed to Phase 2 networking.**

## Part 10 — Phase 2 networking: two peers in byte-identical lockstep

Goal: two separate Dolphin processes, connected by a direct code (no matchmaking service), running the
*same* MKDD match. Built in milestones — M1 transport, M2 shared loop — then spent the real effort on
**cross-process determinism**, which is where every subtle bug lived.

**M1 — transport (`RollbackNet.h/.cpp`).** Raw non-blocking UDP, polled from the CPU thread at field
boundaries (no worker thread, nothing to lock against the rollback loop). Guest drives a HELLO/HELLO_ACK
handshake; host learns the guest's address from `recvfrom` and assigns host = SI port 0, guest = SI
port 1. Every INPUT packet carries a redundant window of the last 16 inputs, so a dropped datagram is
covered by the next without retransmission (the GGPO trick). Localhost RTT ~16 ms.

**M2 — shared match loop.** Each field: read the local pad, apply it delayed by `input_delay`, send the
raw pad keyed to the frame it will apply to; feed the peer's inputs into the `RollbackSession`; a
frame-advantage stall keeps neither peer past what the rollback window can cover. Desync detection
exchanges a guest-RAM hash every 60 frames and logs `*** DESYNC ***` on mismatch.

**The two instances desynced at frame 0 — and fixing it took three independent determinism fixes.**

1. **Initial state didn't match.** Two independently booted instances begin driving at different points
   in their own boot/attract sequence, so "session frame 0" is a different machine on each. Fix: the
   host captures its whole machine and the guest adopts it (`Snapshot::Bytes`/`RestoreBytes`), so both
   start byte-identical. **Non-obvious trap:** the per-frame snapshot *trim* (Part 9, drops fake-VMEM +
   video caches) is validated by an *in-process* self-test — which cannot detect a bad trim, because
   within one process a dropped region simply keeps its identical value across the restore. Across two
   processes those regions differ. The cross-process handoff must transfer the **full untrimmed** state
   (`CaptureFull`): 90 MB, not the trimmed 48 MB. Confirmed the handoff is exact — post-restore RAM
   hash matched the host's to the bit.

2. **One field step still diverged from identical state + identical input.** Root cause: Dolphin's
   global determinism mode (`Core::WantsDeterminism` — deterministic DSP/GPU/SI timing, no idle-skip,
   matching JIT codegen) is only enabled for movies and Dolphin's own NetPlay. Enabled it whenever
   `RollbackNetRole != 0`. That alone hangs boot: `EXI_DeviceIPL`'s `GetGCTime` `ASSERT`s that
   determinism implies a Movie/NetPlay clock, and the failed assert pops a blocking panic dialog in a
   batch process. Fix: give the rollback path its own deterministic clock (shared `CustomRTCValue` +
   emulated ticks), mirroring the Movie/NetPlay branches.

3. **Down to 9 differing bytes — which cascaded.** With determinism on and inputs proven identical
   (dumped both pads: equal), one step still left 9 bytes different: the EXI OS global at `0x800030C0`
   plus a few RNG-like bytes in game RAM. Tiny, but **not** cosmetic — it grew to **1.7 MB by frame
   900**. Root cause: the two instances use different user dirs, so different **memory cards** sat in
   the EXI slots; the OS wrote different EXI globals and it snowballed. Fix: both peers run with EXI
   slots empty (`SlotA/B = None`), exactly as NetPlay forces a matched card. (Memory-card *sync*, so
   saves work, is future work.)

**Result.** Two localhost peers, MEM1 **byte-identical at frame 1 and frame 900** (full 24 MiB),
**0 desyncs over 1000+ frames**, locked ~60 fps, 0 rollbacks, RTT ~16 ms. This is a genuine shared
match: focus a window to drive its player (host = P1, guest = P2), one controller + Alt-Tab works.

**Reproduce.** `tools/play-local.ps1` launches both windows on one machine with every determinism-
critical flag set (single-core, determinism-via-role, EXI empty, host→guest state handoff over a shared
file). Same-machine only for now; real cross-machine play needs the state handoff over the wire (M3),
since the file channel assumes a shared filesystem.
