#ifndef GLASSCAM_FFCS_COLOR_DATA_H
#define GLASSCAM_FFCS_COLOR_DATA_H
#include "ffcs_c.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ffcs_color_data {
    double matrix[9];
    double contrast, saturation, hue, shoulder, toe, grain, grain_size, chroma, sharp;
    uint32_t size, rgb_channels, acros, grain_enabled, reach;
    const uint16_t *lut;
    const double *normalized_codes, *kernel;
} ffcs_color_data;
int ffcs_get_color_data(const FFCSContext *context, ffcs_color_data *output);
#ifdef __cplusplus
}
#endif
#endif
