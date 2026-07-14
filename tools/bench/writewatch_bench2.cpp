// Phase 0 spike v2: dirty-page snapshotting, done the way a real implementation would.
//
// v1 was needlessly pessimistic: it copied every dirty page as its own 4 KiB memcpy
// from a uniformly random scatter across the whole arena. That thrashes the TLB and
// leaves most of the memory bus idle. Two properties of the real problem fix it:
//
//   1. Dirty pages CLUSTER (heaps, entity arrays, framebuffer-adjacent structures),
//      so contiguous runs can be coalesced into one large memcpy.
//   2. A rollback window re-dirties the SAME hot pages frame after frame, so undoing
//      N frames touches far fewer than N x (pages/frame) unique pages. Walking the
//      deltas oldest-first and skipping already-restored pages collapses the work to
//      the unique set.
//
// This build also reports true bulk memcpy bandwidth so the snapshot numbers can be
// read against the machine's actual ceiling.
//
// Build: cl /O2 /EHsc /std:c++17 writewatch_bench2.cpp
// Usage: writewatch_bench2.exe [dirty_pages_per_frame ...]

#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

namespace {
constexpr size_t kPageSize = 4096;
constexpr size_t kMem1Size = 24 * 1024 * 1024;
constexpr size_t kAramSize = 16 * 1024 * 1024;
constexpr size_t kArenaSize = kMem1Size + kAramSize;
constexpr size_t kArenaPages = kArenaSize / kPageSize;
constexpr size_t kMem1Pages = kMem1Size / kPageSize;

// The game's hot working set: where most per-frame writes land.
constexpr size_t kHotRegionPages = 1024;  // 4 MiB
constexpr double kHotFraction = 0.75;     // share of dirty pages inside the hot region
constexpr size_t kMaxRunPages = 8;        // writes arrive in short contiguous runs

constexpr int kRollbackFrames = 7;
constexpr int kFramesPerRun = 300;
constexpr int kWarmupFrames = 60;

double g_qpc_freq = 0.0;

double Now() {
  LARGE_INTEGER t;
  QueryPerformanceCounter(&t);
  return static_cast<double>(t.QuadPart) / g_qpc_freq;
}

struct Stats {
  std::vector<double> samples;
  void Add(double v) { samples.push_back(v); }
  double Mean() const {
    if (samples.empty())
      return 0.0;
    double sum = 0.0;
    for (double s : samples)
      sum += s;
    return sum / samples.size();
  }
  double Percentile(double p) const {
    if (samples.empty())
      return 0.0;
    std::vector<double> sorted = samples;
    std::sort(sorted.begin(), sorted.end());
    return sorted[static_cast<size_t>(p * (sorted.size() - 1))];
  }
  double Max() const {
    return samples.empty() ? 0.0 : *std::max_element(samples.begin(), samples.end());
  }
};

// A frame's undo record: the contents these pages held *before* the frame ran,
// stored as coalesced contiguous runs.
struct Run {
  size_t first_page;
  size_t page_count;
  size_t data_offset;  // into FrameDelta::data
};

struct FrameDelta {
  std::vector<Run> runs;
  std::vector<uint8_t> data;
  void Clear() {
    runs.clear();
    data.clear();
  }
};

void SimulateFrameWrites(uint8_t* arena, size_t dirty_pages, std::mt19937& rng) {
  std::uniform_real_distribution<double> coin(0.0, 1.0);
  std::uniform_int_distribution<size_t> hot_dist(0, kHotRegionPages - 1);
  std::uniform_int_distribution<size_t> cold_dist(0, kMem1Pages - 1);
  std::uniform_int_distribution<size_t> run_dist(1, kMaxRunPages);

  size_t written = 0;
  while (written < dirty_pages) {
    size_t start = (coin(rng) < kHotFraction) ? hot_dist(rng) : cold_dist(rng);
    size_t run = std::min(run_dist(rng), dirty_pages - written);
    for (size_t i = 0; i < run && start + i < kArenaPages; ++i) {
      volatile uint8_t* p = arena + (start + i) * kPageSize;
      p[0] = static_cast<uint8_t>(written);
      p[kPageSize - 1] = static_cast<uint8_t>(written >> 8);
      ++written;
    }
  }
}

bool RunConfig(size_t dirty_pages_target) {
  uint8_t* arena = static_cast<uint8_t*>(VirtualAlloc(
      nullptr, kArenaSize, MEM_RESERVE | MEM_COMMIT | MEM_WRITE_WATCH, PAGE_READWRITE));
  if (!arena) {
    std::fprintf(stderr, "VirtualAlloc(MEM_WRITE_WATCH) failed: %lu\n", GetLastError());
    return false;
  }

  std::vector<uint8_t> shadow(kArenaSize, 0);
  std::vector<FrameDelta> ring(kRollbackFrames + 1);
  std::vector<void*> watch_buf(kArenaPages);
  std::vector<size_t> pages;
  std::vector<bool> restored(kArenaPages, false);
  std::vector<size_t> restored_marks;

  Stats gww_ms, snapshot_ms, restore_ms, dirty_counts, unique_counts;
  std::mt19937 rng(12345);

  ResetWriteWatch(arena, kArenaSize);

  for (int frame = 0; frame < kFramesPerRun; ++frame) {
    SimulateFrameWrites(arena, dirty_pages_target, rng);
    const bool measure = frame >= kWarmupFrames;

    // ---- Per-frame snapshot ----
    double t0 = Now();

    ULONG_PTR count = watch_buf.size();
    ULONG granularity = 0;
    if (GetWriteWatch(WRITE_WATCH_FLAG_RESET, arena, kArenaSize, watch_buf.data(), &count,
                      &granularity) != 0) {
      std::fprintf(stderr, "GetWriteWatch failed\n");
      VirtualFree(arena, 0, MEM_RELEASE);
      return false;
    }
    double t1 = Now();

    pages.clear();
    pages.reserve(count);
    for (ULONG_PTR i = 0; i < count; ++i)
      pages.push_back((static_cast<uint8_t*>(watch_buf[i]) - arena) / kPageSize);
    std::sort(pages.begin(), pages.end());

    FrameDelta& delta = ring[frame % ring.size()];
    delta.Clear();
    delta.data.resize(pages.size() * kPageSize);

    // Coalesce contiguous pages into runs, then copy each run in one memcpy.
    size_t out = 0;
    for (size_t i = 0; i < pages.size();) {
      size_t j = i + 1;
      while (j < pages.size() && pages[j] == pages[j - 1] + 1)
        ++j;
      const size_t first = pages[i];
      const size_t run_pages = j - i;
      const size_t bytes = run_pages * kPageSize;

      delta.runs.push_back({first, run_pages, out});
      // Undo data = pre-frame content, which is exactly what the shadow still holds.
      std::memcpy(&delta.data[out], &shadow[first * kPageSize], bytes);
      // Shadow catches up to live memory.
      std::memcpy(&shadow[first * kPageSize], arena + first * kPageSize, bytes);
      out += bytes;
      i = j;
    }
    double t2 = Now();

    if (measure) {
      gww_ms.Add((t1 - t0) * 1000.0);
      snapshot_ms.Add((t2 - t0) * 1000.0);
      dirty_counts.Add(static_cast<double>(count));
    }

    // ---- Rollback: undo kRollbackFrames ----
    if (measure && frame >= kWarmupFrames + kRollbackFrames) {
      double r0 = Now();
      restored_marks.clear();
      size_t unique = 0;

      // Oldest-first: the oldest delta in the window holds the content we want to
      // land on, so the first writer of a page wins and later frames skip it.
      for (int back = kRollbackFrames - 1; back >= 0; --back) {
        const FrameDelta& d = ring[(frame - back) % ring.size()];
        for (const Run& r : d.runs) {
          // Within a run, copy maximal spans of not-yet-restored pages.
          size_t k = 0;
          while (k < r.page_count) {
            while (k < r.page_count && restored[r.first_page + k])
              ++k;
            if (k >= r.page_count)
              break;
            size_t span_start = k;
            while (k < r.page_count && !restored[r.first_page + k]) {
              restored[r.first_page + k] = true;
              restored_marks.push_back(r.first_page + k);
              ++k;
            }
            const size_t span_pages = k - span_start;
            const size_t page0 = r.first_page + span_start;
            const size_t bytes = span_pages * kPageSize;
            const uint8_t* src = &d.data[r.data_offset + span_start * kPageSize];
            std::memcpy(arena + page0 * kPageSize, src, bytes);
            std::memcpy(&shadow[page0 * kPageSize], src, bytes);
            unique += span_pages;
          }
        }
      }
      double r1 = Now();

      for (size_t p : restored_marks)
        restored[p] = false;

      restore_ms.Add((r1 - r0) * 1000.0);
      unique_counts.Add(static_cast<double>(unique));

      // The restore itself dirtied those pages; clear so the next frame measures
      // only that frame's writes.
      ULONG_PTR discard = watch_buf.size();
      GetWriteWatch(WRITE_WATCH_FLAG_RESET, arena, kArenaSize, watch_buf.data(), &discard,
                    &granularity);
    }
  }

  VirtualFree(arena, 0, MEM_RELEASE);

  std::printf("%7zu | %6.0f | %5.3f %5.3f | %5.2f %5.2f %5.2f | %6.0f | %5.2f %5.2f\n",
              dirty_pages_target, dirty_counts.Mean(), gww_ms.Mean(),
              gww_ms.Percentile(0.99), snapshot_ms.Mean(), snapshot_ms.Percentile(0.99),
              snapshot_ms.Max(), unique_counts.Mean(), restore_ms.Mean(),
              restore_ms.Percentile(0.99));
  return true;
}

void RunBandwidthReference() {
  std::printf("\nBulk memcpy reference (this machine's ceiling):\n");
  const size_t sizes[] = {1u << 20, 4u << 20, 16u << 20, 40u << 20};
  for (size_t size : sizes) {
    std::vector<uint8_t> src(size, 0xAB), dst(size, 0);
    Stats s;
    const int iters = size < (8u << 20) ? 500 : 60;
    for (int i = 0; i < iters; ++i) {
      double t0 = Now();
      std::memcpy(dst.data(), src.data(), size);
      double t1 = Now();
      if (i >= iters / 5)
        s.Add((t1 - t0) * 1000.0);
    }
    const double gbs = (size / (1024.0 * 1024.0 * 1024.0)) / (s.Mean() / 1000.0);
    std::printf("  %3zu MiB: %7.3f ms  -> %5.1f GiB/s\n", size >> 20, s.Mean(), gbs);
  }
}
}  // namespace

int main(int argc, char** argv) {
  LARGE_INTEGER freq;
  QueryPerformanceFrequency(&freq);
  g_qpc_freq = static_cast<double>(freq.QuadPart);

  SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);

  std::vector<size_t> configs;
  for (int i = 1; i < argc; ++i)
    configs.push_back(static_cast<size_t>(std::atoll(argv[i])));
  if (configs.empty())
    configs = {500, 1500, 3000, 6000, 10000};

  std::printf("Dirty-page snapshot benchmark v2 (coalesced runs + dedup restore)\n");
  std::printf("Arena: %zu MiB, page %zu B, %zu pages. Hot region: %zu pages (%.0f%% of writes)\n",
              kArenaSize / (1024 * 1024), kPageSize, kArenaPages, kHotRegionPages,
              kHotFraction * 100.0);
  std::printf("Rollback window: %d frames. Frame budget @60fps: 16.667 ms\n\n",
              kRollbackFrames);

  std::printf("  dirty | actual |  GetWriteWatch |    snapshot/frame   | unique | restore %d fr\n",
              kRollbackFrames);
  std::printf(" target | pages  |  mean   p99    |  mean   p99   max   | pages  |  mean   p99\n");
  std::printf("--------+--------+----------------+---------------------+--------+-------------\n");

  for (size_t c : configs) {
    if (!RunConfig(c))
      return 1;
  }

  RunBandwidthReference();
  return 0;
}
