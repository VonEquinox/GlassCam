#ifndef GLASSCAM_NATIVE_TEST_SUPPORT_H
#define GLASSCAM_NATIVE_TEST_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void hncs_rng_normals(uint64_t seed, size_t n, double *output);
void hncs_rng_floats(uint64_t seed, size_t n, float *output);
void hncs_rng_seed(uint64_t seed, uint64_t *output);
int hdr_post_model(const uint16_t *source, uint16_t *output, size_t count, int stage,
                   double amount, double saturation, int lstar);
#ifdef __cplusplus
}
#endif
#endif
