#include "lumix_c.h"
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
struct Look { const char *key, *name, *asset; int style; };
constexpr Look looks[] = {
    {"standard", "Standard", "L00801", 1}, {"vivid", "Vivid", "L00803", 2},
    {"natural", "Natural", "L00805", 3}, {"monochrome", "Monochrome", "L00831", 4},
    {"landscape", "Landscape", "L00811", 5}, {"portrait", "Portrait", "L00813", 6},
    {"l-monochrome", "L.Monochrome", "L00815", 8}, {"like709", "Like709", "L00827", 11},
    {"l-monochrome-d", "L.Monochrome D", "L00817", 13}, {"flat", "Flat", "L00809", 14},
    {"cinelike-d2", "Cinelike D2", "L00823", 16}, {"cinelike-v2", "Cinelike V2", "L00825", 17},
    {"l-monochrome-s", "L.Monochrome S", "L00819", 18}, {"classic-neo", "L.Classic Neo", "L00807", 19},
    {"leica-monochrome", "Leica Monochrome", "L00835", 20}, {"cinelike-a2", "Cinelike A2", "L00821", 21}
};
void fail(char *error, size_t size, const char *message) {
    if (error && size) std::snprintf(error, size, "%s", message);
}
uint32_t u32(const unsigned char *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
uint16_t rounded(double x) {
    return static_cast<uint16_t>(std::clamp(std::floor(x + 0.5), 0.0, 65535.0));
}
uint16_t u16(const unsigned char *p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
// The original x86 CVTTSD2SI + 16-bit store truncates and retains low bits.
// Define it explicitly so NaN/black and over-range inputs are portable on ARM.
uint16_t truncated(double x) {
    if (!std::isfinite(x)) return 0;
    double value = std::fmod(std::trunc(x), 65536.0);
    return static_cast<uint16_t>(value < 0 ? value + 65536.0 : value);
}
struct Point { double x, y; };
struct Curve {
    std::array<Point, 49> points{};
    size_t count = 0;
    double convert(double value) const {
        if (count < 2) return value;
        size_t i = 0;
        // Native ConvertInternal(...,false) extrapolates the first/last segment.
        while (i + 2 < count && value >= points[i+1].x) ++i;
        const auto a = points[i], b = points[i+1];
        return a.y + (b.y-a.y)*(value-a.x)/(b.x-a.x);
    }
};

// Move RGB toward its equal-luma neutral, preserving the chroma direction.
// The output knee approaches the cube boundary continuously instead of clipping
// channels independently. Input projection leaves every in-gamut value intact.
void boundChroma(std::array<double, 3> &rgb, bool soft) {
    const double y = std::clamp((rgb[0]*0.299+rgb[1]*0.587)+rgb[2]*0.114, 0.0, 1.0);
    if (y <= 0 || y >= 1) { rgb.fill(y); return; }
    double radius = 0;
    for (double value : rgb) {
        const double delta = value-y;
        radius = std::max(radius, delta >= 0 ? delta/(1-y) : -delta/y);
    }
    const double knee = soft ? 0.95 : 1.0;
    if (radius <= knee) return;
    const double distance = radius-knee;
    const double bounded = soft ? knee + distance/(1+distance/(1-knee)) : 1;
    for (double &value : rgb) value = std::clamp(y+(value-y)*(bounded/radius), 0.0, 1.0);
}
}

struct LUMIXContext {
    std::vector<uint16_t> cube;
    bool fullPipeline = false;
    std::array<unsigned char,70> contrast{};
    std::array<unsigned char,196> lowISO{};
    std::array<unsigned char,3> monochrome{};
    uint16_t saturation = 128;
    // Native 129-node LUT: step=32 over a 12-bit domain, with a guard node.
    static constexpr size_t grid = 129, step = 32;
    void sample(const uint16_t *input, uint16_t *output) const {
        size_t ix[3]; double f[3];
        for (size_t c = 0; c < 3; ++c) {
            ix[c] = std::min<size_t>(input[c] / step, grid - 2);
            f[c] = double(input[c] % step) / step;
        }
        const double r = f[0], g = f[1], b = f[2];
        // Match Pana_LUT::GetValue's addition order, including its floor(x+.5).
        // Its native table is B-fast; this lossless resource is R-fast RGB.
        const double w[8] = {(1-b)*(1-g)*(1-r), b*(1-g)*(1-r),
                              (1-b)*g*(1-r), (1-b)*(1-g)*r,
                              b*g*(1-r), b*(1-g)*r, (1-b)*g*r, b*g*r};
        const size_t offsets[8] = {0, grid*grid, grid, 1,
                                   grid*grid+grid, grid*grid+1, grid+1, grid*grid+grid+1};
        const size_t base = (ix[2]*grid+ix[1])*grid+ix[0];
        for (size_t c = 0; c < 3; ++c) {
            double value = 0;
            for (size_t i = 0; i < 8; ++i) value += cube[(base+offsets[i])*3+c] * w[i];
            output[c] = rounded(value);
        }
    }
    Curve contrastCurve(double white) const {
        Curve curve; curve.count = 1;
        double x = 0, y = 0;
        for (size_t i = 0; i < 28; ++i) {
            unsigned power = (u16(contrast.data()+(i/4)*2) >> ((i%4)*4)) & 15;
            if (!power) break;
            x += 1U << power; y += u16(contrast.data()+14+i*2);
            curve.points[curve.count++] = {x*(white/16384.0), y*(white/512.0)};
        }
        return curve;
    }
    Curve lowISOCurve(double white) const {
        Curve curve;
        if (u16(lowISO.data()+96) != 65535 || u16(lowISO.data()+194) != 65535) return curve;
        curve.count = 49;
        for (size_t i = 0; i < curve.count; ++i)
            curve.points[i] = {u16(lowISO.data()+i*2)*(white/65535.0),u16(lowISO.data()+98+i*2)*(white/65535.0)};
        return curve;
    }
    void filter(const uint16_t *input, uint16_t *output, double white, double gain, int space,
                const Curve &tone, const Curve &pre) const {
        double r=input[0], g=input[1], b=input[2];
        if (space==1) {
            const double nr=rounded((r-b)*(r>=b?0.0234375:0.03125)+(r-g)*(r>=g?-0.33984375:-0.46484375)+r);
            const double ng=rounded((g-r)*(g>=r?0.10546875:0.01171875)+g);
            const double nb=rounded((b-g)*(b>=g?-0.04296875:-0.08984375)+(b-r)*-0.0078125+b);
            r=nr;g=ng;b=nb;
        }
        // Preserve the SSE addition order. Ghidra's algebraic presentation
        // reverses these sums, which changes a subsequent integer truncation.
        double y=(r*0.299+g*0.587)+b*0.114;
        const double ratio=pre.convert(y)*gain/y, scale=4095.0/white;
        uint16_t normalized[3]={truncated(truncated(r*ratio)*scale),truncated(truncated(g*ratio)*scale),truncated(truncated(b*ratio)*scale)};
        uint16_t mapped[3]; sample(normalized,mapped);
        r=truncated(mapped[0]/scale);g=truncated(mapped[1]/scale);b=truncated(mapped[2]/scale);
        y=(r*0.299+g*0.587)+b*0.114;
        double cb,cr;
        if (monochrome[0]) {
            const int blueChroma=monochrome[2]-(monochrome[2]>=128?256:0);
            const int redChroma=monochrome[1]-(monochrome[1]>=128?256:0);
            cb=(blueChroma*4)/scale;cr=(redChroma*4)/scale;
        } else {
            cb=((r*-0.1687+g*-0.3313)+b*0.5)*saturation*0.0078125;
            cr=((r*0.5+g*-0.4187)+b*-0.0813)*saturation*0.0078125;
        }
        const double contrastRatio=tone.convert(y)/y;
        output[0]=truncated(rounded(cr*1.402+y)*contrastRatio);
        output[1]=truncated(rounded(cr*-0.71414+(cb*-0.34414+y))*contrastRatio);
        output[2]=truncated(rounded(cb*1.772+y)*contrastRatio);
    }

    std::array<double, 3> filterIPhone(std::array<double, 3> rgb, const Curve &tone) const {
        boundChroma(rgb, false);
        uint16_t coordinates[3], mapped[3];
        for (size_t c = 0; c < 3; ++c) coordinates[c] = rounded(rgb[c]*4095);
        sample(coordinates, mapped);
        for (size_t c = 0; c < 3; ++c) rgb[c] = mapped[c]/4095.0;
        const double y = (rgb[0]*0.299+rgb[1]*0.587)+rgb[2]*0.114;
        if (y == 0) return {0, 0, 0};
        double cb, cr;
        if (monochrome[0]) {
            cb = (int(monochrome[2])-(monochrome[2]>=128?256:0))*4/4095.0;
            cr = (int(monochrome[1])-(monochrome[1]>=128?256:0))*4/4095.0;
        } else {
            cb = ((rgb[0]*-0.1687+rgb[1]*-0.3313)+rgb[2]*0.5)*saturation*0.0078125;
            cr = ((rgb[0]*0.5+rgb[1]*-0.4187)+rgb[2]*-0.0813)*saturation*0.0078125;
        }
        const double ratio = tone.convert(y)/y;
        rgb = {(cr*1.402+y)*ratio, (cr*-0.71414+(cb*-0.34414+y))*ratio, (cb*1.772+y)*ratio};
        boundChroma(rgb, true);
        return rgb;
    }
};

static std::vector<uint16_t> loadCube(const char *directory, const std::string &asset) {
        const std::string path = std::string(directory) + "/" + asset + ".lmx";
        std::ifstream stream(path, std::ios::binary | std::ios::ate);
        if (!stream) throw std::runtime_error("The original LUMIX LUT is missing");
        auto length = stream.tellg();
        constexpr size_t rawSize = LUMIXContext::grid * LUMIXContext::grid * LUMIXContext::grid * 6;
        if (length < 32 || length > static_cast<std::streamoff>(rawSize + 65536)) throw std::runtime_error("Invalid LUMIX resource size");
        stream.seekg(0);
        std::vector<unsigned char> packed(static_cast<size_t>(length));
        stream.read(reinterpret_cast<char *>(packed.data()), length);
        if (!stream || std::memcmp(packed.data(), "GLUMIX1\0", 8) || u32(packed.data()+8) != 129 ||
            u32(packed.data()+12) != 32 || u32(packed.data()+16) != 4095 || u32(packed.data()+20) != rawSize ||
            u32(packed.data()+28) != 1) throw std::runtime_error("Invalid LUMIX LUT header");
        std::vector<unsigned char> bytes(rawSize);
        uLongf decodedSize = bytes.size();
        if (uncompress(bytes.data(), &decodedSize, packed.data()+32, packed.size()-32) != Z_OK || decodedSize != rawSize ||
            crc32(0, bytes.data(), static_cast<uInt>(bytes.size())) != u32(packed.data()+24))
            throw std::runtime_error("LUMIX LUT decompression or checksum failed");
        std::vector<uint16_t> result(rawSize/2);
        for (size_t i = 0; i < result.size(); ++i) result[i] = u16(bytes.data()+i*2);
        return result;
}

extern "C" {
size_t lumix_look_count(void) { return sizeof(looks) / sizeof(looks[0]); }
const char *lumix_look_key(size_t i) { return i < lumix_look_count() ? looks[i].key : nullptr; }
const char *lumix_look_name(size_t i) { return i < lumix_look_count() ? looks[i].name : nullptr; }
LUMIXContext *lumix_create(const char *directory, size_t look, char *error, size_t size) {
    try {
        if (!directory || !*directory || look >= lumix_look_count()) throw std::runtime_error("Invalid LUMIX look or resource directory");
        auto result = std::make_unique<LUMIXContext>();
        result->cube = loadCube(directory, looks[look].asset);
        fail(error, size, "");
        return result.release();
    } catch (const std::exception &e) { fail(error, size, e.what()); return nullptr; }
}
LUMIXContext *lumix_create_pipeline(const char *directory, size_t look, double kelvin, int contrast,
                                   int saturation, int iso, char *error, size_t size) {
    try {
        if (!directory || !*directory || look >= lumix_look_count() || !std::isfinite(kelvin) ||
            kelvin < 2000 || kelvin > 10000 || contrast < 0 || contrast > 20 || saturation < 0 ||
            saturation > 20 || iso < 1 || iso > 1000000) throw std::runtime_error("Invalid LUMIX pipeline settings");
        std::ifstream stream(std::string(directory)+"/pipeline.lmp",std::ios::binary);
        std::vector<unsigned char> regs((std::istreambuf_iterator<char>(stream)),{});
        constexpr size_t payloadSize = 21*70+21*2+21*3+3*0x10e0+64;
        if (regs.size()!=payloadSize+24 || std::memcmp(regs.data(),"GLUMIX2\0",8) ||
            u32(regs.data()+8)!=2 || u32(regs.data()+12)!=payloadSize || u32(regs.data()+20)!=106 ||
            crc32(0,regs.data()+24,payloadSize)!=u32(regs.data()+16)) throw std::runtime_error("Invalid LUMIX pipeline registers or checksum");
        auto result = std::make_unique<LUMIXContext>();
        // Original MakeUpVEParam's four-point CCT curve; Set3DLUT clamps the
        // selector to the first/second cube outside 256...512. Interior node
        // mixing uses integer division, before trilinear interpolation.
        Curve temperature; temperature.count=4;
        std::memcpy(temperature.points.data(),regs.data()+24+payloadSize-64,64);
        const int selector=std::clamp<int>(static_cast<int>(temperature.convert(kelvin)),256,512);
        const unsigned secondWeight=512-selector;
        const std::string first=looks[look].asset;
        char second[32]; std::snprintf(second,sizeof(second),"L%05d",std::stoi(first.substr(1))+1);
        result->cube=loadCube(directory,secondWeight==256?std::string(second):first);
        if (secondWeight>0 && secondWeight<256) {
            const auto alternate=loadCube(directory,second);
            for (size_t i=0;i<result->cube.size();++i)
                result->cube[i]=(uint32_t(result->cube[i])*(256-secondWeight)+uint32_t(alternate[i])*secondWeight)/256;
        }
        const auto p=regs.data()+24;
        std::memcpy(result->contrast.data(),p+contrast*70,70);
        result->saturation=u16(p+1470+saturation*2);
        const int style=looks[look].style;
        if ((0x942110U>>style)&1) std::memcpy(result->monochrome.data(),p+1512+saturation*3,3);
        int pre=iso==50?0:iso==64?1:iso==80?2:-1;
        // iPhone input has no Panasonic PhotoStyle EXIF; native source style=0.
        if (pre>=0) std::memcpy(result->lowISO.data(),p+1575+pre*0x10e0+style*196,196);
        result->fullPipeline=true;
        fail(error,size,"");return result.release();
    } catch (const std::exception &e) { fail(error,size,e.what());return nullptr; }
}
void lumix_destroy(LUMIXContext *context) { delete context; }
int lumix_process_rgb12(const LUMIXContext *context, const uint16_t *input, size_t pixels,
                        uint16_t *output, char *error, size_t size) {
    if (!context || !input || !output || !pixels || pixels > std::numeric_limits<size_t>::max()/6) {
        fail(error, size, "Invalid LUMIX RGB12 buffers"); return 0;
    }
    for (size_t i = 0; i < pixels*3; ++i) if (input[i] > 4095) {
        fail(error, size, "LUMIX RGB12 values must be in 0...4095"); return 0;
    }
    for (size_t i = 0; i < pixels; ++i) context->sample(input+i*3, output+i*3);
    fail(error, size, ""); return 1;
}
int lumix_process_rgb16(const LUMIXContext *context, const uint16_t *input, size_t pixels,
                        double white, double ev, int space, uint16_t *output, char *error, size_t size) {
    if (!context || !context->fullPipeline || !input || !output || !pixels ||
        pixels>std::numeric_limits<size_t>::max()/6 || !std::isfinite(white) || white<=0 || white>65535 ||
        !std::isfinite(ev) || ev < -10 || ev > 10 || (space!=0 && space!=1)) {
        fail(error,size,"Invalid LUMIX RGB16 pipeline buffers or parameters");return 0;
    }
    const auto tone=context->contrastCurve(white),pre=context->lowISOCurve(white);
    const double gain=std::exp2(ev);
    for(size_t i=0;i<pixels;i++)context->filter(input+i*3,output+i*3,white,gain,space,tone,pre);
    fail(error,size,"");return 1;
}
int lumix_process_linear_rgba(const LUMIXContext *context, const float *input, size_t inputCount,
                              size_t pixels, double ev, float *output, size_t outputCount,
                              char *error, size_t size) {
    if (!context || !input || !output || !pixels || pixels > std::numeric_limits<size_t>::max()/16 ||
        inputCount != pixels*3 || outputCount != pixels*4 || !std::isfinite(ev) || ev < -32 || ev > 32) {
        fail(error, size, "Invalid LUMIX image buffers or exposure"); return 0;
    }
    for (size_t i = 0; i < inputCount; ++i) if (!std::isfinite(input[i])) {
        fail(error, size, "LUMIX input must be finite"); return 0;
    }
    const double gain = std::exp2(ev);
    const auto tone=context->contrastCurve(65535),pre=context->lowISOCurve(65535);
    for (size_t i = 0; i < pixels; ++i) {
        uint16_t rgb[3], rendered[3];
        const double white=context->fullPipeline?65535.0:4095.0;
        for (size_t c = 0; c < 3; ++c) rgb[c] = rounded(std::clamp(double(input[i*3+c])*gain, 0.0, 1.0)*white);
        if (context->fullPipeline) context->filter(rgb,rendered,white,1,0,tone,pre);
        else context->sample(rgb, rendered);
        for (size_t c = 0; c < 3; ++c) {
            const double x = std::clamp(double(rendered[c])/white, 0.0, 1.0);
            output[i*4+c] = static_cast<float>(x <= 0.04045 ? x/12.92 : std::pow((x+0.055)/1.055, 2.4));
        }
        output[i*4+3] = 1;
    }
    fail(error, size, ""); return 1;
}
int lumix_process_iphone_rgba(const LUMIXContext *context, const float *input, size_t inputCount,
                              size_t pixels, double ev, float *output, size_t outputCount,
                              char *error, size_t size) {
    if (!context || !context->fullPipeline || !input || !output || !pixels ||
        pixels > std::numeric_limits<size_t>::max()/16 || inputCount != pixels*3 ||
        outputCount != pixels*4 || !std::isfinite(ev) || ev < -32 || ev > 32) {
        fail(error, size, "Invalid LUMIX iPhone buffers or exposure"); return 0;
    }
    for (size_t i = 0; i < inputCount; ++i) if (!std::isfinite(input[i])) {
        fail(error, size, "LUMIX input must be finite"); return 0;
    }
    const double gain = std::exp2(ev);
    const auto tone = context->contrastCurve(1);
    for (size_t i = 0; i < pixels; ++i) {
        // Panasonic low-ISO sensor compensation is intentionally absent here.
        // iPhone ISO numbers do not characterize a Panasonic sensor response.
        auto rgb = context->filterIPhone({input[i*3]*gain, input[i*3+1]*gain, input[i*3+2]*gain}, tone);
        for (size_t c = 0; c < 3; ++c) {
            const double x = rgb[c];
            output[i*4+c] = static_cast<float>(x <= 0.04045 ? x/12.92 : std::pow((x+0.055)/1.055, 2.4));
        }
        output[i*4+3] = 1;
    }
    fail(error, size, ""); return 1;
}
}
