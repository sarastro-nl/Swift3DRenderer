#ifndef render_hpp
#define render_hpp

#include <simd/simd.h>
#include <stdint.h>

typedef struct {
    uint32_t *buffer;
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

typedef struct {
    uint32_t index;
    simd_float2 mapping;
} texture_t;

typedef union {
    simd_float3 color;
    texture_t texture;
} color_attribute_t;

typedef enum { color = 0, texture } disc_t;

typedef struct {
    const simd_float4 normal;
    const disc_t disc;
    const color_attribute_t color_attribute;
} vertex_attribute_t;

#endif /* render_hpp */
