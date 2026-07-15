// Microbenchmark: how fast can we copy a 40 MiB (MEM1+ARAM) rollback snapshot on this machine, and
// does the strategy (plain memcpy vs non-temporal streaming) or thread count change anything?
//
// Answers whether per-frame snapshots are core-bound (threading helps) or already at the per-core
// memory-bandwidth wall (only copying *fewer bytes* helps). On the dev machine (i9-9900KF) the
// answer was: memcpy is already optimal, NT stores are marginally slower, threading does nothing.
// See docs/benchmarks.md Part 4. Self-contained; re-run on any target machine.
//
//   cl /O2 /std:c++17 /EHsc copybench.cpp        (x64 Developer prompt)

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <chrono>
#include <thread>
#include <vector>
#include <algorithm>

#if defined(_M_X64) || defined(__x86_64__)
#include <emmintrin.h>
#define HAVE_NT 1
#endif

using Clock = std::chrono::steady_clock;

static constexpr std::size_t kSnap = 40u * 1024 * 1024;  // MEM1(24)+ARAM(16)
static constexpr int kDestPool = 8;                      // round-robin cold destinations
static constexpr int kIters = 40;

// Non-temporal streaming copy: writes straight to memory, bypassing cache / write-allocate.
static void StreamCopy(void* dst, const void* src, std::size_t size)
{
#if defined(HAVE_NT)
  auto* d = static_cast<std::uint8_t*>(dst);
  const auto* s = static_cast<const std::uint8_t*>(src);
  const std::size_t misalign = reinterpret_cast<std::uintptr_t>(d) & 15u;
  if (misalign)
  {
    const std::size_t n = std::min<std::size_t>(16u - misalign, size);
    std::memcpy(d, s, n);
    d += n; s += n; size -= n;
  }
  std::size_t i = 0;
  const std::size_t bulk = size & ~std::size_t(63);
  for (; i < bulk; i += 64)
  {
    _mm_stream_si128(reinterpret_cast<__m128i*>(d + i),
                     _mm_loadu_si128(reinterpret_cast<const __m128i*>(s + i)));
    _mm_stream_si128(reinterpret_cast<__m128i*>(d + i + 16),
                     _mm_loadu_si128(reinterpret_cast<const __m128i*>(s + i + 16)));
    _mm_stream_si128(reinterpret_cast<__m128i*>(d + i + 32),
                     _mm_loadu_si128(reinterpret_cast<const __m128i*>(s + i + 32)));
    _mm_stream_si128(reinterpret_cast<__m128i*>(d + i + 48),
                     _mm_loadu_si128(reinterpret_cast<const __m128i*>(s + i + 48)));
  }
  if (i < size)
    std::memcpy(d + i, s + i, size - i);
  _mm_sfence();
#else
  std::memcpy(dst, src, size);
#endif
}

enum class How { Memcpy, Stream };

static void CopyRange(How how, std::uint8_t* d, const std::uint8_t* s, std::size_t n)
{
  if (how == How::Stream) StreamCopy(d, s, n);
  else std::memcpy(d, s, n);
}

static void OneCopy(How how, int threads, std::uint8_t* dst, const std::uint8_t* src)
{
  if (threads <= 1) { CopyRange(how, dst, src, kSnap); return; }
  std::vector<std::thread> pool;
  pool.reserve(threads);
  const std::size_t chunk = (kSnap / threads) & ~std::size_t(63);
  for (int t = 0; t < threads; ++t)
  {
    const std::size_t off = t * chunk;
    const std::size_t n = (t == threads - 1) ? (kSnap - off) : chunk;
    pool.emplace_back([how, dst, src, off, n] { CopyRange(how, dst + off, src + off, n); });
  }
  for (auto& th : pool) th.join();
}

static double MeasureMs(How how, int threads, std::uint8_t* pool, const std::uint8_t* src)
{
  for (int i = 0; i < 4; ++i)
    OneCopy(how, threads, pool + (i % kDestPool) * kSnap, src);
  std::vector<double> samples;
  for (int i = 0; i < kIters; ++i)
  {
    std::uint8_t* dst = pool + (i % kDestPool) * kSnap;
    const auto t0 = Clock::now();
    OneCopy(how, threads, dst, src);
    const auto t1 = Clock::now();
    samples.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
  }
  std::sort(samples.begin(), samples.end());
  return samples[samples.size() / 2];
}

int main()
{
  auto* src = static_cast<std::uint8_t*>(_aligned_malloc(kSnap, 4096));
  auto* pool = static_cast<std::uint8_t*>(_aligned_malloc(kSnap * kDestPool, 4096));
  if (!src || !pool) { std::printf("alloc failed\n"); return 1; }
  for (std::size_t i = 0; i < kSnap; ++i)
    src[i] = static_cast<std::uint8_t>(i * 2654435761u >> 13);
  std::memset(pool, 0, kSnap * kDestPool);

  std::printf("Copy of %zu MiB, median of %d iters (%d cold dest buffers)\n",
              kSnap / (1024 * 1024), kIters, kDestPool);
  std::printf("%-10s %8s %10s %10s\n", "strategy", "threads", "ms", "GB/s");
  for (How how : {How::Memcpy, How::Stream})
    for (int th : {1, 2, 4, 8})
    {
      const double ms = MeasureMs(how, th, pool, src);
      std::printf("%-10s %8d %10.2f %10.2f\n", how == How::Memcpy ? "memcpy" : "stream", th, ms,
                  (kSnap / 1e9) / (ms / 1e3));
    }
  _aligned_free(src);
  _aligned_free(pool);
  return 0;
}
