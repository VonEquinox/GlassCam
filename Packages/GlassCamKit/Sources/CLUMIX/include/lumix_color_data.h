#ifndef GLASSCAM_LUMIX_COLOR_DATA_H
#define GLASSCAM_LUMIX_COLOR_DATA_H
#include "lumix_c.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct lumix_color_data {
    const uint16_t *cube;
    double tone_x[49], tone_y[49];
    uint32_t tone_count, saturation, monochrome;
    int32_t blue_chroma, red_chroma;
} lumix_color_data;
int lumix_get_color_data(const LUMIXContext *context, lumix_color_data *output);
#ifdef __cplusplus
}
#endif
#endif
