#ifndef render_hpp
#define render_hpp

#include <simd/simd.h>
#include <stdint.h>

typedef struct {
    uint32_t *buffer;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerPixel;
    uint32_t bufferSize;
} PixelData;

typedef struct {
    float up;
    float down;
    float left;
    float right;
    simd_float2 mouse;
} Input;

#endif /* render_hpp */
