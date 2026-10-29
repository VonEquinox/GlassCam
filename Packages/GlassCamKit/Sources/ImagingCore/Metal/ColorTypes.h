#ifndef GLASSCAM_COLOR_TYPES_H
#define GLASSCAM_COLOR_TYPES_H
#ifdef __METAL_VERSION__
typedef uint GCColorUInt;
typedef int GCColorInt;
#else
#include <stdint.h>
typedef uint32_t GCColorUInt;
typedef int32_t GCColorInt;
#endif
struct GCColorRegion {
    GCColorInt offsetX, offsetY, inputX, inputTop;
    GCColorUInt inputWidth, inputHeight, outputWidth, outputHeight, fullWidth, fullHeight, seed;
    float preExposure, backendExposure;
};
struct GCFFCSColor {
    float matrix[9];
    float contrast, saturation, hue, shoulder, toe, grain, grainSize, chroma, sharp;
    GCColorUInt size, rgbChannels, acros, grainEnabled, reach;
};
struct GCLUMIXColor {
    float toneX[49], toneY[49];
    GCColorUInt toneCount, saturation, monochrome;
    GCColorInt blueChroma, redChroma;
};
#endif
