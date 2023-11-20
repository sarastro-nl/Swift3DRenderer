#include <simd/simd.h>
#include "render.hpp"
#include "../data-generator/data.hpp"

extern "C" {

#include <string.h>

typedef struct {
    simd_float3 camera_position;
    struct { simd_float3 x; simd_float3 y; simd_float3 z; } camera_axis;
    simd_float4x4 camera_matrix;
    float mouseX;
    float mouseY;
} state_t;

typedef struct {
    float *buffer;
    int32_t buffer_size;
} depth_buffer_t;

typedef struct {
    float near;
    float fov;
    float scale;
    float factor;
    float speed;
    float rotation_speed;
    uint32_t background_color;
} config_t;

typedef struct {
    simd_float3 point;
    simd_float3 normal;
    simd_float3 color;
} attribute_t;

#define RGB(r, g, b) (((((uint8_t)(r) << 8) + (uint8_t)(g)) << 8) + (uint8_t)(b))

state_t state = {
    .camera_position = simd_make_float3(0, 0, 0),
    .camera_axis = { .x = simd_make_float3(1, 0, 0), .y = simd_make_float3(0, 1, 0), .z = simd_make_float3(0, 0, 1)},
    .camera_matrix = matrix_identity_float4x4,
    .mouseX = 0,
    .mouseY = 0,
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
    .background_color = RGB(50, 50, 50),
};

simd_float3 camera_vertices[world_vertices_count];
simd_float3 raster_vertices[world_vertices_count];
attribute_t attributes[world_attributes_count];

inline
float edge_function(const simd_float3 *v1, const simd_float3 *v2, const simd_float3 *v3) {
    return (v3->x - v1->x) * (v1->y - v2->y) + (v3->y - v1->y) * (v2->x - v1->x);
}

void update_camera(const Input *input) {
    bool changed = false;
    if (input->left > 0 || input->right > 0 || input->up > 0 || input->down > 0) {
        changed = true;
        state.camera_position += config.speed * ((input->right - input->left) * state.camera_axis.x + (input->down - input->up) * state.camera_axis.z);
    }
    if (input->mouseX != state.mouseX || input->mouseY != state.mouseY) {
        changed = true;
        simd_float3 z = (state.mouseX - input->mouseX) * state.camera_axis.x + (state.mouseY - input->mouseY) * state.camera_axis.y + (100 / config.rotation_speed) * state.camera_axis.z;
        simd_float3 nz = simd_normalize(z);
        simd_quatf q = simd_quaternion(state.camera_axis.z, nz);
        state.camera_axis.x = simd_normalize(simd_act(q, state.camera_axis.x));
        state.camera_axis.y = simd_normalize(simd_act(q, state.camera_axis.y));
        state.camera_axis.z = nz;
        state.mouseX = input->mouseX;
        state.mouseY = input->mouseY;
    }
    if (changed) {
        state.camera_matrix = simd_inverse(simd_matrix(simd_make_float4(state.camera_axis.x, 0),
                                                       simd_make_float4(state.camera_axis.y, 0),
                                                       simd_make_float4(state.camera_axis.z, 0),
                                                       simd_make_float4(state.camera_position, 1)));
    }
}

void updateAndRender(const PixelData *pixel_data, const Input *input) {
    update_camera(input);
    
    int32_t depth_buffer_size = pixel_data->width * pixel_data->height * sizeof(float);
    if (depth_buffer.buffer_size != depth_buffer_size) {
        depth_buffer.buffer_size = depth_buffer_size;
        depth_buffer.buffer = (float *)realloc(depth_buffer.buffer, depth_buffer_size);
        config.factor = config.near * pixel_data->height / (2 * config.scale);
    }
    float infinity = HUGE_VALF;
    memset_pattern4(depth_buffer.buffer, &infinity, depth_buffer.buffer_size);
    memset_pattern4(pixel_data->pixelBuffer, &config.background_color, pixel_data->bufferSize);

    float width = (float)pixel_data->width;
    float height = (float)pixel_data->height;
    for (int i = 0; i < world_vertices_count; i++) {
        simd_float4 v = simd_mul(state.camera_matrix, world_vertices[i]);
        camera_vertices[i] = v.xyz;
        raster_vertices[i] = simd_make_float3(v.x, -v.y, 0) * config.factor / -v.z + simd_make_float3(width / 2, height / 2, -v.z);
    }
    for (int i = 0; i < world_attributes_count; i++) {
        vertex_attribute_t a = world_attributes[i];
        simd_float4 n = simd_mul(state.camera_matrix, a.normal);
        attributes[i] = { .point = simd_make_float3(0, 0, 0), .normal = n.xyz, .color = a.color };
    }
    for (int i = 0; i < world_triangles_count; i++) {
        int32_t vi1 = world_vertex_indexes[i * 3];
        int32_t vi2 = world_vertex_indexes[i * 3 + 1];
        int32_t vi3 = world_vertex_indexes[i * 3 + 2];
        simd_float3 rv1 = raster_vertices[vi1];
        simd_float3 rv2 = raster_vertices[vi2];
        simd_float3 rv3 = raster_vertices[vi3];
        simd_float3 rvmin = simd_min(simd_min(rv1, rv2), rv3);
        simd_float3 rvmax = simd_max(simd_max(rv1, rv2), rv3);
        if (rvmin.x > width || rvmin.y > height || rvmax.x < 0 || rvmax.y < 0 || rvmin.z < config.near) { continue; }
        
        float area = edge_function(&rv1, &rv2, &rv3);
        int32_t ai1 = world_attribute_indexes[i * 3];
        int32_t ai2 = world_attribute_indexes[i * 3 + 1];
        int32_t ai3 = world_attribute_indexes[i * 3 + 2];
        attribute_t a1 = attributes[ai1];
        attribute_t a2 = attributes[ai2];
        attribute_t a3 = attributes[ai3];
        simd_float3 rvz = 1 / simd_make_float3(rv1.z, rv2.z, rv3.z);
        attribute_t preMul1 = { .point = camera_vertices[vi1] * rvz[0], .normal = a1.normal * rvz[0], .color = a1.color * rvz[0] };
        attribute_t preMul2 = { .point = camera_vertices[vi2] * rvz[1], .normal = a2.normal * rvz[1], .color = a2.color * rvz[1] };
        attribute_t preMul3 = { .point = camera_vertices[vi3] * rvz[2], .normal = a3.normal * rvz[2], .color = a3.color * rvz[2] };
        int32_t xmin = std::fmax(0, (int)rvmin.x);
        int32_t xmax = std::fmin((int)pixel_data->width - 1, (int)rvmax.x);
        int32_t ymin = std::fmax(0, (int)rvmin.y);
        int32_t ymax = std::fmin((int)pixel_data->height - 1, (int)rvmax.y);
        for (int y = ymin; y <= ymax; y++) {
            int32_t ypart = y * (int)pixel_data->width;
            for (int x = xmin; x <= xmax; x++) {
                simd_float3 p = simd_make_float3((float)x + 0.5, (float)y + 0.5, 0);
                simd_float3 w = simd_make_float3(edge_function(&rv2, &rv3, &p), edge_function(&rv3, &rv1, &p), edge_function(&rv1, &rv2, &p));
                if (w.x >= 0 && w.y >= 0 && w.z >= 0) {
                    w /= area;
                    float z = 1 / simd_dot(rvz, w);
                    int32_t xpart = x + ypart;
                    if (z < depth_buffer.buffer[xpart]) {
                        depth_buffer.buffer[xpart] = z;
                        simd_float3 point = z * (preMul1.point * w[0] + preMul2.point * w[1] + preMul3.point * w[2]);
                        simd_float3 normal = z * (preMul1.normal * w[0] + preMul2.normal * w[1] + preMul3.normal * w[2]);
                        simd_float3 color = z * (preMul1.color * w[0] + preMul2.color * w[1] + preMul3.color * w[2]);
                        simd_float3 p = -simd_normalize(point);
                        simd_float3 n = simd_normalize(normal);
                        float dot = simd_dot(p, n);
                        pixel_data->pixelBuffer[xpart] = RGB(dot * color[0], dot * color[1], dot * color[2]);
                    }
                }
            }
        }
    }
}

}
