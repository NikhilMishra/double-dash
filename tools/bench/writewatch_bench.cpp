// Phase 0 spike: is dirty-page snapshotting fast enough for rollback?
//
// This measures the *mechanism* on this machine, standalone — no Dolphin needed.
// We model Dolphin's GameCube memory arena (MEM1 24 MiB + ARAM 16 MiB), dirty a
// configurable number of pages per "frame" (MKDD's real number is still unknown;
// Brawl measures ~1500/frame), then time the snapshot/restore path a rollback
// implementation would actually run.
//
// Snapshot design (the one a real implementation must use):
//   We keep a shadow copy of the arena equal to live memory as of the last frame.
//   Each frame: GetWriteWatch(RESET) -> dirty pages. For each dirty page, push
//   (page, shadow_content) into this frame's delta (that is the PRE-frame content,
//   which is what undoing the frame requires), then refresh shadow from live.
//   Rolling back N frames = replay deltas in reverse, writing old content back.
//
// Build (VS2019 x64 native tools prompt or via vcvars):
//   cl /O2 /EHsc /std:c++17 writewatch_bench.cpp
//
// Usage: writewatch_bench.exe [dirty_pages_per_frame ...]

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
constexpr size_t kMem1Size = 24 * 1024 * 1024;  // GameCube MEM1
constexpr size_t kAramSize = 16 * 1024 * 1024;  // ARAM
constexpr size_t kArenaSize = kMem1Size + kAramSize;
constexpr size_t kArenaPages = kArenaSize / kPageSize;

// Rollback window we design for.
constexpr int kRollbackFrames = 7;
// Frames to run per configuration; the first few are discarded as warmup.
constexpr int kFramesPerRun = 300;
constexpr int kWarmupFrames = 60;

double g_qpc_freq = 0.0;

double Now() {
  LARGE_INTEGER t;
  QueryPerformanceCounter(&t);
  return static_cast<double>(t.QuadPart) / g_qpc_freq;
}

// One frame's undo information: the contents these pages had *before* the frame.
struct FrameDelta {
  std::vector<size_t> page_indices;
  std::vector<uint8_t> page_data;  // page_indices.size() * kPageSize

  void Clear() {
    page_indices.clear();
    page_data.clear();
  }
};

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
    size_t idx = static_cast<size_t>(p * (sorted.size() - 1));
    return sorted[idx];
  }

  double Max() const {
    if (samples.empty())
      return 0.0;
    return *std::max_element(samples.begin(), samples.end());
  }
};

// Scatter writes across the arena the way a game engine would: a hot working set
// (physics, entities, RNG) plus a spread of incidental touches.
void SimulateFrameWrites(uint8_t* arena, size_t dirty_pages, std::mt19937& rng) {
  std::uniform_int_distribution<size_t> page_dist(0, kArenaPages - 1);
  for (size_t i = 0; i < dirty_pages; ++i) {
    size_t page = page_dist(rng);
    // Touch a few cache lines in the page rather than the whole page — a dirty
    // page costs the same to snapshot however little of it changed.
    volatile uint8_t* p = arena + page * kPageSize;
    p[0] = static_cast<uint8_t>(i);
    p[64] = static_cast<uint8_t>(i >> 8);
    p[kPageSize - 1] = static_cast<uint8_t>(i);
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

  Stats getwritewatch_ms, snapshot_ms, restore_ms, dirty_counts;
  std::mt19937 rng(12345);

  // Reset the write-watch state so warmup starts clean.
  ResetWriteWatch(arena, kArenaSize);

  for (int frame = 0; frame < kFramesPerRun; ++frame) {
    SimulateFrameWrites(arena, dirty_pages_target, rng);

    const bool measure = frame >= kWarmupFrames;

    // --- Per-frame snapshot ---
    double t0 = Now();

    ULONG_PTR count = watch_buf.size();
    ULONG granularity = 0;
    UINT rc = GetWriteWatch(WRITE_WATCH_FLAG_RESET, arena, kArenaSize, watch_buf.data(),
                            &count, &granularity);
    double t1 = Now();
    if (rc != 0) {
      std::fprintf(stderr, "GetWriteWatch failed (rc=%u)\n", rc);
      VirtualFree(arena, 0, MEM_RELEASE);
      return false;
    }

    FrameDelta& delta = ring[frame % ring.size()];
    delta.Clear();
    delta.page_indices.reserve(count);
    delta.page_data.resize(count * kPageSize);

    for (ULONG_PTR i = 0; i < count; ++i) {
      size_t page = (static_cast<uint8_t*>(watch_buf[i]) - arena) / kPageSize;
      delta.page_indices.push_back(page);
      // Undo data = what the page held *before* this frame == the shadow.
      std::memcpy(&delta.page_data[i * kPageSize], &shadow[page * kPageSize], kPageSize);
      // Shadow catches up to live memory.
      std::memcpy(&shadow[page * kPageSize], arena + page * kPageSize, kPageSize);
    }
    double t2 = Now();

    if (measure) {
      getwritewatch_ms.Add((t1 - t0) * 1000.0);
      snapshot_ms.Add((t2 - t0) * 1000.0);
      dirty_counts.Add(static_cast<double>(count));
    }

    // --- Rollback: undo kRollbackFrames, as a misprediction would ---
    if (measure && frame >= kWarmupFrames + kRollbackFrames) {
      double r0 = Now();
      for (int back = 0; back < kRollbackFrames; ++back) {
        const FrameDelta& d = ring[(frame - back) % ring.size()];
        for (size_t i = 0; i < d.page_indices.size(); ++i) {
          size_t page = d.page_indices[i];
          std::memcpy(arena + page * kPageSize, &d.page_data[i * kPageSize], kPageSize);
          std::memcpy(&shadow[page * kPageSize], &d.page_data[i * kPageSize], kPageSize);
        }
      }
      double r1 = Now();
      restore_ms.Add((r1 - r0) * 1000.0);

      // The rollback rewound live memory, so the pages we just touched are dirty
      // again from the OS's point of view. Clear that so the next frame's
      // measurement reflects only that frame's writes.
      ULONG_PTR discard_count = watch_buf.size();
      GetWriteWatch(WRITE_WATCH_FLAG_RESET, arena, kArenaSize, watch_buf.data(),
                    &discard_count, &granularity);
    }
  }

  VirtualFree(arena, 0, MEM_RELEASE);

  std::printf("%8zu | %7.0f | %6.3f %6.3f | %6.3f %6.3f %6.3f | %6.2f %6.2f\n",
              dirty_pages_target, dirty_counts.Mean(), getwritewatch_ms.Mean(),
              getwritewatch_ms.Percentile(0.99), snapshot_ms.Mean(),
              snapshot_ms.Percentile(0.99), snapshot_ms.Max(), restore_ms.Mean(),
              restore_ms.Percentile(0.99));
  return true;
}

void RunFullCopyBaseline() {
  std::vector<uint8_t> src(kArenaSize, 0xAB);
  std::vector<uint8_t> dst(kArenaSize, 0);
  Stats s;
  for (int i = 0; i < 50; ++i) {
    double t0 = Now();
    std::memcpy(dst.data(), src.data(), kArenaSize);
    double t1 = Now();
    if (i >= 10)
      s.Add((t1 - t0) * 1000.0);
  }
  std::printf("\nBaseline: full %zu MiB arena memcpy = %.3f ms (mean), %.3f ms (p99)\n",
              kArenaSize / (1024 * 1024), s.Mean(), s.Percentile(0.99));
  std::printf("  (a naive full-RAM snapshot every frame would cost at least this)\n");
}
}  // namespace

int main(int argc, char** argv) {
  LARGE_INTEGER freq;
  QueryPerformanceFrequency(&freq);
  g_qpc_freq = static_cast<double>(freq.QuadPart);

  // Keep the OS from migrating us mid-measurement.
  SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
  SetThreadAffinityMask(GetCurrentThread(), 1);

  std::vector<size_t> configs;
  for (int i = 1; i < argc; ++i)
    configs.push_back(static_cast<size_t>(std::atoll(argv[i])));
  if (configs.empty())
    configs = {500, 1500, 3000, 6000, 10000};

  std::printf("Dirty-page snapshot benchmark\n");
  std::printf("Arena: %zu MiB (MEM1 %zu + ARAM %zu), page %zu B, %zu pages total\n",
              kArenaSize / (1024 * 1024), kMem1Size / (1024 * 1024),
              kAramSize / (1024 * 1024), kPageSize, kArenaPages);
  std::printf("Rollback window: %d frames. Frame budget @60fps: 16.667 ms\n\n",
              kRollbackFrames);

  std::printf("  dirty | actual  |   GetWriteWatch |      snapshot/frame    |  restore %d frames\n",
              kRollbackFrames);
  std::printf(" target | pages   |   mean    p99   |  mean    p99    max    |  mean    p99\n");
  std::printf("--------+---------+-----------------+------------------------+----------------\n");

  for (size_t c : configs) {
    if (!RunConfig(c))
      return 1;
  }

  RunFullCopyBaseline();
  return 0;
}
