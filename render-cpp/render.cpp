#include <simd/simd.h>
#include <algorithm>
#include "render.hpp"
#include "../data-generator/data.hpp"

extern "C" {

#include <string.h>

typedef struct {
    simd_float3 camera_position;
    struct { simd_float3 x; simd_float3 y; simd_float3 z; } camera_axis;
    simd_float4x4 camera_matrix;
    simd_float2 mouse;
} state_t;

typedef struct {
    float *buffer;
    int32_t buffer_size;
} depth_buffer_t;

typedef struct {
    const float near;
    const float fov;
    const float scale;
    float factor;
    const float speed;
    const float rotation_speed;
    const uint32_t background_color;
} config_t;

typedef struct {
    simd_float3 point;
    simd_float3 normal;
    simd_float3 color;
} attribute_t;

typedef struct {
    simd_float3 w;
    simd_float3 wy;
    const simd_float3 dx;
    const simd_float3 dy;
} weight_t;

typedef struct {
    uint32_t *pbuffer;
    float *dbuffer;
    const int xDelta;
} pointers_t;

#define RGB(r, g, b) (((((uint8_t)(r) << 8) + (uint8_t)(g)) << 8) + (uint8_t)(b))
#define EDGE_FUNCTION(a, b, c) ((c.x - a.x) * (a.y - b.y) + (c.y - a.y) * (b.x - a.x))

state_t state = {
    .camera_position = simd_make_float3(0, 0, 0),
    .camera_axis = { .x = simd_make_float3(1, 0, 0), .y = simd_make_float3(0, 1, 0), .z = simd_make_float3(0, 0, 1)},
    .camera_matrix = matrix_identity_float4x4,
    .mouse = simd_make_float2(0, 0),
};

depth_buffer_t depth_buffer = {
    .buffer = NULL,
    .buffer_size = 0,
};

config_t config = {
    .near = 0.1,
    .fov = M_PI / 5,
    .scale = config.near * tan(config.fov / 2),
    .factor = 1,
    .speed = 0.1,
    .rotation_speed = 0.1,
    .background_color = RGB(30, 30, 30),
};

simd_float3 camera_vertices[world_vertices_count];
simd_float3 raster_vertices[world_vertices_count];
attribute_t attributes[world_attributes_count];

void update_camera(const Input *input) {
    bool changed = false;
    if (input->left > 0 || input->right > 0 || input->up > 0 || input->down > 0) {
        changed = true;
        state.camera_position += config.speed * ((input->right - input->left) * state.camera_axis.x + (input->down - input->up) * state.camera_axis.z);
    }
    if (input->mouse.x != state.mouse.x || input->mouse.y != state.mouse.y) {
        changed = true;
        const simd_float3 z = (state.mouse.x - input->mouse.x) * state.camera_axis.x + (state.mouse.y - input->mouse.y) * state.camera_axis.y + (100 / config.rotation_speed) * state.camera_axis.z;
        const simd_float3 nz = simd_normalize(z);
        const simd_quatf q = simd_quaternion(state.camera_axis.z, nz);
        state.camera_axis.x = simd_normalize(simd_act(q, state.camera_axis.x));
        state.camera_axis.y = simd_normalize(simd_act(q, state.camera_axis.y));
        state.camera_axis.z = nz;
        state.mouse.x = input->mouse.x;
        state.mouse.y = input->mouse.y;
    }
    if (changed) {
        state.camera_matrix = simd_inverse(simd_matrix(simd_make_float4(state.camera_axis.x, 0),
                                                       simd_make_float4(state.camera_axis.y, 0),
                                                       simd_make_float4(state.camera_axis.z, 0),
                                                       simd_make_float4(state.camera_position, 1)));
    }
}

__attribute__((visibility("default")))
void updateAndRender(const PixelData *pixel_data, const Input *input) {
    update_camera(input);
    
    const int32_t depth_buffer_size = pixel_data->width * pixel_data->height * sizeof(float);
    if (depth_buffer.buffer_size != depth_buffer_size) {
        depth_buffer.buffer_size = depth_buffer_size;
        depth_buffer.buffer = (float *)realloc(depth_buffer.buffer, depth_buffer_size);
        config.factor = config.near * pixel_data->height / (2 * config.scale);
    }
    memset(depth_buffer.buffer, 0, depth_buffer.buffer_size);
    memset_pattern4(pixel_data->buffer, &config.background_color, pixel_data->bufferSize);

    const float width = (float)pixel_data->width;
    const float height = (float)pixel_data->height;
    for (int i = 0; i < world_vertices_count; i++) {
        const simd_float4 v = simd_mul(state.camera_matrix, world_vertices[i]);
        camera_vertices[i] = v.xyz;
        raster_vertices[i] = simd_make_float3(v.x, -v.y, 0) * config.factor / -v.z + simd_make_float3(width / 2, height / 2, -v.z);
    }
    for (int i = 0; i < world_attributes_count; i++) {
        const vertex_attribute_t a = world_attributes[i];
        attributes[i] = { .point = simd_make_float3(0, 0, 0), .normal = simd_mul(state.camera_matrix, a.normal).xyz, .color = a.color };
    }
    for (int i = 0; i < world_triangles_count * 3; i += 3) {
        const int32_t vi1 = vertex_indexes[i];
        const int32_t vi2 = vertex_indexes[i + 1];
        const int32_t vi3 = vertex_indexes[i + 2];
        const simd_float3 rv1 = raster_vertices[vi1];
        const simd_float3 rv2 = raster_vertices[vi2];
        const simd_float3 rv3 = raster_vertices[vi3];
        const simd_float3 rvmin = simd_min(simd_min(rv1, rv2), rv3);
        const simd_float3 rvmax = simd_max(simd_max(rv1, rv2), rv3);
        if (rvmin.x > width || rvmin.y > height || rvmax.x < 0 || rvmax.y < 0 || rvmin.z < config.near) { continue; }
        
        const attribute_t a1 = attributes[attribute_indexes[i]];
        const attribute_t a2 = attributes[attribute_indexes[i + 1]];
        const attribute_t a3 = attributes[attribute_indexes[i + 2]];
        const simd_float3 rvz = 1 / simd_make_float3(rv1.z, rv2.z, rv3.z);
        const attribute_t preMul1 = { .point = camera_vertices[vi1] * rvz[0], .normal = a1.normal * rvz[0], .color = a1.color * rvz[0] };
        const attribute_t preMul2 = { .point = camera_vertices[vi2] * rvz[1], .normal = a2.normal * rvz[1], .color = a2.color * rvz[1] };
        const attribute_t preMul3 = { .point = camera_vertices[vi3] * rvz[2], .normal = a3.normal * rvz[2], .color = a3.color * rvz[2] };
        const int32_t xmin = std::max(0, (int)rvmin.x);
        const int32_t xmax = std::min(pixel_data->width - 1, (int)rvmax.x);
        const int32_t ymin = std::max(0, (int)rvmin.y);
        const int32_t ymax = std::min(pixel_data->height - 1, (int)rvmax.y);
        const float oneOverArea = 1 / EDGE_FUNCTION(rv1, rv2, rv3);
        const simd_float2 p = simd_make_float2((float)xmin + 0.5, (float)ymin + 0.5);
        const simd_float3 wstart = simd_make_float3(EDGE_FUNCTION(rv2, rv3, p), EDGE_FUNCTION(rv3, rv1, p), EDGE_FUNCTION(rv1, rv2, p));
        weight_t weight = {
            .w = wstart, .wy = wstart,
            .dx = simd_make_float3(rv2.y - rv3.y, rv3.y - rv1.y, rv1.y - rv2.y),
            .dy = simd_make_float3(rv3.x - rv2.x, rv1.x - rv3.x, rv2.x - rv1.x) };
        const int32_t bufferStart = ymin * pixel_data->width + xmin;
        pointers_t pointers = {
            .pbuffer = pixel_data->buffer + bufferStart,
            .dbuffer = depth_buffer.buffer + bufferStart,
            .xDelta = pixel_data->width - xmax + xmin - 1,
        };
        for (int y = ymin; y <= ymax; y++) {
            for (int x = xmin; x <= xmax; x++) {
                if (weight.w[0] >= 0 && weight.w[1] >= 0 && weight.w[2] >= 0) {
                    simd_float3 w = oneOverArea * weight.w;
                    const float z = simd_dot(rvz, w);
                    if (z > *pointers.dbuffer) {
                        *pointers.dbuffer = z;
                        w /= z;
                        const simd_float3 point = -simd_normalize(preMul1.point * w[0] + preMul2.point * w[1] + preMul3.point * w[2]);
                        const simd_float3 normal = simd_normalize(preMul1.normal * w[0] + preMul2.normal * w[1] + preMul3.normal * w[2]);
                        const simd_float3 color = preMul1.color * w[0] + preMul2.color * w[1] + preMul3.color * w[2];
                        const simd_float3 shadedColor = simd_dot(point, normal) * color;
                        *pointers.pbuffer = RGB(shadedColor[0], shadedColor[1], shadedColor[2]);
                    }
                }
                pointers.pbuffer++;
                pointers.dbuffer++;
                weight.w += weight.dx;
            }
            pointers.pbuffer += pointers.xDelta;
            pointers.dbuffer += pointers.xDelta;
            weight.wy += weight.dy;
            weight.w = weight.wy;
        }
    }
}

}
