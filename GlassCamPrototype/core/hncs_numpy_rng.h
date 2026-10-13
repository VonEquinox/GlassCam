#ifndef HNCS_NUMPY_RNG_H
#define HNCS_NUMPY_RNG_H

#include <cstdint>

namespace hncs_spatial {

// NumPy 2.3.5 default_rng(uint64_seed).standard_normal() double stream.
// Use next_float() for standard_normal(...).astype(np.float32), which differs
// from standard_normal(..., dtype=np.float32). Each instance has independent
// mutable state; do not concurrently call one instance from multiple threads.
// Requires GCC/Clang unsigned __int128 (supported by Apple Clang on arm64/x64).
// Compile with normal IEEE floating-point semantics, without -ffast-math.
// The rare tail branch calls host log1p/exp; last-bit double differences across
// libm implementations remain possible even with identical raw PCG64 streams.
class NumpyNormal {
 public:
  explicit NumpyNormal(std::uint64_t seed) noexcept;
  double next() noexcept;
  float next_float() noexcept { return static_cast<float>(next()); }

 private:
#if !defined(__SIZEOF_INT128__)
#error "NumpyNormal requires a compiler supporting unsigned __int128"
#endif
  using uint128 = __uint128_t;
  uint128 state_ = 0;
  uint128 increment_ = 0;
  std::uint64_t next_raw() noexcept;
  double next_uniform() noexcept;
};

}  // namespace hncs_spatial
#endif  // HNCS_NUMPY_RNG_H
