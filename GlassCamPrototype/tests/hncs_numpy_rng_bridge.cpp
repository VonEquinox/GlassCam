#include "../core/hncs_numpy_rng.cpp"
extern "C" void hncs_rng_normals(uint64_t seed, size_t n, double* output) {
  hncs_spatial::NumpyNormal rng(seed);
  for (size_t i=0; i<n; ++i) output[i] = rng.next();
}
extern "C" void hncs_rng_floats(uint64_t seed, size_t n, float* output) {
  hncs_spatial::NumpyNormal rng(seed);
  for (size_t i=0; i<n; ++i) output[i] = rng.next_float();
}
extern "C" void hncs_rng_seed(uint64_t seed, uint64_t* output) {
  auto result = hncs_spatial::seed_words(seed);
  for (unsigned i=0; i<4; ++i) output[i] = result[i];
}
