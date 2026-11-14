#ifndef GLASSCAM_LUMIX_C_H
#define GLASSCAM_LUMIX_C_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct LUMIXContext LUMIXContext;
size_t lumix_look_count(void);
const char *lumix_look_key(size_t index);
const char *lumix_look_name(size_t index);
/* Original S1M2 SDR Photo Style LUTs, extracted without grid reduction.
 * Immutable contexts are safe for concurrent renders. Failure never returns
 * an identity look or silently selects another color engine. */
LUMIXContext *lumix_create(const char *asset_directory, size_t look,
                           char *error, size_t error_size);
/* Revision 2: complete native SDR VE branch. CCT selects/mixes both original
 * cubes; contrast/saturation use native indices 0...20 (neutral=10). Source ISO
 * selects the original S1M2 low-ISO table at exactly 50, 64 or 80. */
LUMIXContext *lumix_create_pipeline(const char *asset_directory, size_t look,
                                   double kelvin, int contrast, int saturation, int source_iso,
                                   char *error, size_t error_size);
void lumix_destroy(LUMIXContext *context);
/* Exact native Pana_LUT interpolation for 12-bit RGB. Used by the oracle check.
 * Packed RGB input/output; input values must be <=4095. Returns 1 on success.
 * Exact in-place RGB is supported; partially overlapping buffers are rejected. */
int lumix_process_rgb12(const LUMIXContext *context, const uint16_t *input,
                        size_t pixels, uint16_t *output, char *error, size_t error_size);
/* Independent 48-bit native oracle entry. Packed RGB, scalar source white;
 * color_space=0 uses sRGB input, 1 uses the native alternate input transform.
 * compensation_ev is the VE stage's internal luminance compensation. */
int lumix_process_rgb16(const LUMIXContext *context, const uint16_t *input,
                        size_t pixels, double white, double compensation_ev, int color_space,
                        uint16_t *output, char *error, size_t error_size);
/* iPhone source adapter: linear sRGB -> EV -> RGB48 -> native SDR VE branch ->
 * sRGB EOTF -> Float32 linear RGBA. Legacy contexts keep the revision-1 RGB12
 * LUT adapter. The caller splits/restores HDR headroom. This is not a Panasonic
 * sensor calibration or a full SILKYPIX RW2 decoder. RGB input and RGBA output
 * must not overlap; invalid requests leave pixel buffers unchanged. */
int lumix_process_linear_rgba(const LUMIXContext *context, const float *input,
                              size_t input_count, size_t pixels, double exposure_ev,
                              float *output, size_t output_count,
                              char *error, size_t error_size);
/* Revision 4 iPhone adapter: complete Photo Style cubes and native CCT,
 * contrast/saturation/monochrome registers, with bounded RGB12 coordinates,
 * float chroma/tone output and continuous, luma-preserving gamut compression.
 * Omits Panasonic sensor-specific low-ISO compensation. No UInt16 wraparound.
 * Input is linear sRGB after caller-owned HDR splitting; finite signed values
 * are projected into the LUT gamut. Output is linear RGBA in [0,1], alpha=1.
 * RGB input and RGBA output must not overlap.
 * Legacy/oracle APIs above retain their exact original arithmetic. */
int lumix_process_iphone_rgba(const LUMIXContext *context, const float *input,
                              size_t input_count, size_t pixels, double exposure_ev,
                              float *output, size_t output_count,
                              char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
#endif
