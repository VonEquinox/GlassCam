// Keep the private seed_words check isolated from the linked product RNG symbols.
#define hncs_spatial hncs_test_rng
#include "../Sources/CHNCS/hncs_numpy_rng.cpp"
#undef hncs_spatial
extern "C" void hncs_rng_normals(uint64_t seed, size_t n, double* output) {
  hncs_test_rng::NumpyNormal rng(seed);
  for (size_t i=0; i<n; ++i) output[i] = rng.next();
}
extern "C" void hncs_rng_floats(uint64_t seed, size_t n, float* output) {
  hncs_test_rng::NumpyNormal rng(seed);
  for (size_t i=0; i<n; ++i) output[i] = rng.next_float();
}
extern "C" void hncs_rng_seed(uint64_t seed, uint64_t* output) {
  auto result = hncs_test_rng::seed_words(seed);
  for (unsigned i=0; i<4; ++i) output[i] = result[i];
}
