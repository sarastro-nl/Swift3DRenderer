#ifndef render_hpp
#define render_hpp

#include <simd/simd.h>
#include <stdint.h>

typedef struct {
    uint32_t *pixelBuffer;
    int32_t width;
    int32_t height;
    int32_t bytesPerPixel;
    int32_t bufferSize;
} PixelData;

typedef struct {
    float up;
    float down;
    float left;
    float right;
    simd_float2 mouse;
} Input;

#endif /* render_hpp */
