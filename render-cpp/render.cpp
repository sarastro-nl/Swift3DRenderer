#include <simd/simd.h>
#include <functional>
#include <sys/syslimits.h>
#include <dlfcn.h>
#include "render.hpp"

extern "C" {

#include <string.h>

#define RGB(r, g, b) (((((uint8_t)(r) << 8) + (uint8_t)(g)) << 8) + (uint8_t)(b))
#define EDGE_FUNCTION(a, b, c) ((c.x - a.x) * (a.y - b.y) + (c.y - a.y) * (b.x - a.x))

typedef struct {
    uint32_t index;
    simd_float2 uv;
} texture_t;

typedef union {
    simd_float3 color;
    texture_t texture;
} color_attribute_t;

typedef enum { color = 0, texture } disc_t;

typedef struct {
    const simd_float4 normal;
    const color_attribute_t color_attribute;
    const disc_t disc;
} vertex_attribute_t;

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

struct {
    simd_float3 camera_position;
    struct { simd_float3 x; simd_float3 y; simd_float3 z; } camera_axis;
    simd_float4x3 camera_matrix;
    simd_float2 mouse;
} state = {
    .camera_position = simd_make_float3(0, 0, 0),
    .camera_axis = { .x = simd_make_float3(1, 0, 0), .y = simd_make_float3(0, 1, 0), .z = simd_make_float3(0, 0, 1)},
    .camera_matrix = simd_matrix_from_rows(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(0, 0, 1, 0)),
    .mouse = simd_make_float2(0, 0),
};

struct {
    float *buffer;
    int32_t buffer_size;
} depth_buffer = {
    .buffer = NULL,
    .buffer_size = 0,
};

struct {
    uint32_t *buffer;
} texture_buffer = {
    .buffer = NULL,
};

struct {
    const float near;
    const float fov;
    const float scale;
    float factor;
    const float speed;
    const float rotation_speed;
    const uint32_t background_color;
} config = {
    .near = 0.1,
    .fov = M_PI / 5,
    .scale = config.near * tan(config.fov / 2),
    .factor = 1,
    .speed = 0.1,
    .rotation_speed = 0.3,
    .background_color = RGB(30, 30, 30),
};

struct {
    simd_float4 *vertices;
    uint64_t vertex_count;
    uint64_t *vertex_indices;
    uint64_t vertex_indices_count;
    vertex_attribute_t *attributes;
    uint64_t attributes_count;
    uint64_t *attribute_indices;
    uint64_t attribute_indices_count;
    
    simd_float3 *camera_vertices;
    simd_float3 *raster_vertices;
    simd_float3 *normals;
} scene = {0};

__attribute__((always_inline))
int32_t nextPowerOfTwo(int32_t i) {
    i--;
    i |= i >> 1;
    i |= i >> 2;
    i |= i >> 4;
    return i + 1;
}

__attribute__((always_inline))
simd_float3 getTextureColor(uint32_t *buffer, simd_float2 uv, simd_float2 level) {
    int32_t levelX = nextPowerOfTwo(std::max(std::min((int32_t)level.x, 256), 1));
    int32_t levelY = nextPowerOfTwo(std::max(std::min((int32_t)level.y, 256), 1));
//    levelX = 256;
//    levelY = 256;
    int32_t x = (int32_t)(fmodf(uv.x, 1) * levelX) + (511 & ~(2 * levelX - 1));
    int32_t y = (int32_t)(fmodf(uv.y, 1) * levelY) + (511 & ~(2 * levelY - 1));
    uint32_t rgb = *(buffer + x + (y << 9));
    return simd_make_float3((float)(rgb >> 16), (float)((rgb >> 8) & 255), (float)(rgb & 255));
}

void update_camera(const Input *input) {
    bool changed = false;
    if (input->left > 0 || input->right > 0 || input->up > 0 || input->down > 0) {
        changed = true;
        state.camera_position += config.speed * ((input->right - input->left) * state.camera_axis.x + (input->down - input->up) * state.camera_axis.z);
    }
    if (input->mouse.x != state.mouse.x || input->mouse.y != state.mouse.y) {
        changed = true;
        const simd_float3 z = simd_fast_normalize((state.mouse.x - input->mouse.x) * state.camera_axis.x +
                                                  (state.mouse.y - input->mouse.y) * state.camera_axis.y +
                                                  (100 / config.rotation_speed)    * state.camera_axis.z);
        const simd_quatf q = simd_quaternion(state.camera_axis.z, z);
        state.camera_axis.x = simd_fast_normalize(simd_act(q, state.camera_axis.x));
        state.camera_axis.y = simd_fast_normalize(simd_act(q, state.camera_axis.y));
        state.camera_axis.z = z;
        state.mouse.x = input->mouse.x;
        state.mouse.y = input->mouse.y;
    }
    if (changed) {
        state.camera_matrix = simd_matrix_from_rows(simd_make_float4(state.camera_axis.x, -simd_dot(state.camera_axis.x, state.camera_position)),
                                                    simd_make_float4(state.camera_axis.y, -simd_dot(state.camera_axis.y, state.camera_position)),
                                                    simd_make_float4(state.camera_axis.z, -simd_dot(state.camera_axis.z, state.camera_position)));
    }
}

void updateAndRender(const PixelData *pixel_data, const Input *input);

void initialize() {
    Dl_info info;
    dladdr((const void *)updateAndRender, &info);
    char path[PATH_MAX];
    strcpy(path, info.dli_fname);
    FILE *fp;
    char *p = strrchr(path, '/');
    strcpy(p, "/data.bin"); // iOS
    if ((fp = fopen(path, "r")) == NULL) {
        strcpy(p, "/Resources/data.bin"); // macOS
        if ((fp = fopen(path, "r")) == NULL) {
            strcpy(p, "/../data-generator/data.bin"); // cmd line
            if ((fp = fopen(path, "r")) == NULL) {
                exit(666);
            }
        }
    }
    uint64_t *count = (uint64_t *)malloc(2 * sizeof(uint64_t));
    fread(count, sizeof(uint64_t), 2, fp);
    scene.vertex_count = *count;
    scene.vertices = (simd_float4 *)malloc(*count * sizeof(simd_float4));
    fread(scene.vertices, sizeof(simd_float4), *count, fp);
    scene.camera_vertices = (simd_float3 *)malloc(*count * sizeof(simd_float3));
    scene.raster_vertices = (simd_float3 *)malloc(*count * sizeof(simd_float3));
    
    fread(count, sizeof(uint64_t), 2, fp);
    scene.vertex_indices_count = *count;
    uint64_t aligned_count = *count + (*count % 2);
    scene.vertex_indices = (uint64_t *)malloc(aligned_count * sizeof(uint64_t));
    fread(scene.vertex_indices, sizeof(uint64_t), aligned_count, fp);
    
    fread(count, sizeof(uint64_t), 2, fp);
    scene.attributes_count = *count;
    scene.attributes = (vertex_attribute_t *)malloc(*count * sizeof(vertex_attribute_t));
    fread(scene.attributes, sizeof(vertex_attribute_t), *count, fp);
    scene.normals = (simd_float3 *)malloc(*count * sizeof(simd_float3));

    fread(count, sizeof(uint64_t), 2, fp);
    scene.attribute_indices_count = *count;
    aligned_count = *count + (*count % 2);
    scene.attribute_indices = (uint64_t *)malloc(aligned_count * sizeof(uint64_t));
    fread(scene.attribute_indices, sizeof(uint64_t), aligned_count, fp);

    fread(count, sizeof(uint64_t), 2, fp);
    texture_buffer.buffer = (uint32_t *)malloc(*count * sizeof(uint32_t));
    fread(texture_buffer.buffer, sizeof(uint32_t), *count, fp);
}

__attribute__((visibility("default")))
void updateAndRender(const PixelData *pixel_data, const Input *input) {
    static bool initialized = false;
    if (!initialized) {
        initialized = true;
        initialize();
    }
    
    update_camera(input);
    
    const int32_t depth_buffer_size = pixel_data->width * pixel_data->height * sizeof(float);
    if (depth_buffer.buffer_size != depth_buffer_size) {
        depth_buffer.buffer_size = depth_buffer_size;
        depth_buffer.buffer = (float *)realloc(depth_buffer.buffer, depth_buffer_size);
        config.factor = config.near * pixel_data->height / (2 * config.scale);
    }
    memset(depth_buffer.buffer, 0, depth_buffer.buffer_size);
    memset_pattern4(pixel_data->buffer, &config.background_color, pixel_data->bufferSize);

    const simd_float2 size = simd_make_float2((float)pixel_data->width, (float)pixel_data->height);
    for (int i = 0; i < scene.vertex_count; i++) {
        const simd_float3 v = simd_mul(state.camera_matrix, scene.vertices[i]);
        scene.camera_vertices[i] = v;
        if (v.z > -config.near) {
            scene.raster_vertices[i] = simd_make_float3(0);
        } else {
            scene.raster_vertices[i] = simd_make_float3(v.x, -v.y, 0) * config.factor / -v.z + simd_make_float3(size / 2, -v.z);
        }
    }
    for (int i = 0; i < scene.attributes_count; i++) {
        scene.normals[i] = simd_mul(state.camera_matrix, scene.attributes[i].normal);
    }
    for (int i = 0; i < scene.vertex_indices_count; i += 3) {
        const int64_t vi1 = scene.vertex_indices[i];
        const int64_t vi2 = scene.vertex_indices[i + 1];
        const int64_t vi3 = scene.vertex_indices[i + 2];
        const simd_float3 rv1 = scene.raster_vertices[vi1];
        const simd_float3 rv2 = scene.raster_vertices[vi2];
        const simd_float3 rv3 = scene.raster_vertices[vi3];
        const simd_float3 rvmin = simd_min(simd_min(rv1, rv2), rv3);
        if (rvmin.x >= size[0] || rvmin.y >= size[1] || rvmin.z < config.near) { continue; }
        const simd_float3 rvmax = simd_max(simd_max(rv1, rv2), rv3);
        if (rvmax.x < 0 || rvmax.y < 0) { continue; }
        const float area = EDGE_FUNCTION(rv1, rv2, rv3);
        if (area < 10) { continue; }
        const float oneOverArea = 1 / area;
        const int32_t xmin = std::max(0, (int)rvmin.x);
        const int32_t xmax = std::min(pixel_data->width - 1, (int)rvmax.x);
        const int32_t ymin = std::max(0, (int)rvmin.y);
        const int32_t ymax = std::min(pixel_data->height - 1, (int)rvmax.y);
        const simd_float2 p = simd_make_float2((float)xmin + 0.5, (float)ymin + 0.5);
        const simd_float3 wstart = simd_make_float3(EDGE_FUNCTION(rv2, rv3, p), EDGE_FUNCTION(rv3, rv1, p), EDGE_FUNCTION(rv1, rv2, p)) * oneOverArea;
        weight_t weight = {
            .w = wstart, .wy = wstart,
            .dx = simd_make_float3(rv2.y - rv3.y, rv3.y - rv1.y, rv1.y - rv2.y) * oneOverArea,
            .dy = simd_make_float3(rv3.x - rv2.x, rv1.x - rv3.x, rv2.x - rv1.x) * oneOverArea };
        const int32_t bufferStart = ymin * pixel_data->width + xmin;
        pointers_t pointers = {
            .pbuffer = pixel_data->buffer + bufferStart,
            .dbuffer = depth_buffer.buffer + bufferStart,
            .xDelta = pixel_data->width - xmax + xmin - 1,
        };
        
        const int64_t ai1 = scene.attribute_indices[i];
        const int64_t ai2 = scene.attribute_indices[i + 1];
        const int64_t ai3 = scene.attribute_indices[i + 2];
        const vertex_attribute_t a1 = scene.attributes[ai1];
        const vertex_attribute_t a2 = scene.attributes[ai2];
        const vertex_attribute_t a3 = scene.attributes[ai3];
        const simd_float3 rvz = 1 / simd_make_float3(rv1.z, rv2.z, rv3.z);
        const simd_float3 p1 = scene.camera_vertices[vi1] * rvz[0];
        const simd_float3 p2 = scene.camera_vertices[vi2] * rvz[1];
        const simd_float3 p3 = scene.camera_vertices[vi3] * rvz[2];
        const simd_float3 n1 = scene.normals[ai1] * rvz[0];
        const simd_float3 n2 = scene.normals[ai2] * rvz[1];
        const simd_float3 n3 = scene.normals[ai3] * rvz[2];
        std::function<simd_float3(simd_float3, float)> getColor;
        if (a1.disc == color) {
            const simd_float3 cc1 = a1.color_attribute.color * rvz[0];
            const simd_float3 cc2 = a2.color_attribute.color * rvz[1];
            const simd_float3 cc3 = a3.color_attribute.color * rvz[2];
            getColor = [cc1, cc2, cc3] (const simd_float3 w, const float z) { return cc1 * w[0] + cc2 * w[1] + cc3 * w[2];};
        } else if (a1.disc == texture) {
            uint32_t *buffer = texture_buffer.buffer + ((int32_t)a1.color_attribute.texture.index << 18);
            const simd_float2 tm1 = a1.color_attribute.texture.uv * rvz[0];
            const simd_float2 tm2 = a2.color_attribute.texture.uv * rvz[1];
            const simd_float2 tm3 = a3.color_attribute.texture.uv * rvz[2];
            const simd_float2 dz = simd_make_float2(simd_dot(rvz, weight.dx), simd_dot(rvz, weight.dy));
            const simd_float2 tpp = (tm1 * simd_make_float2(weight.dx[0], weight.dy[0]) +
                                     tm2 * simd_make_float2(weight.dx[1], weight.dy[1]) +
                                     tm3 * simd_make_float2(weight.dx[2], weight.dy[2]));
            getColor = [buffer, tm1, tm2, tm3, dz, tpp] (const simd_float3 w, const float z) {
                const simd_float2 mapping = tm1 * w[0] + tm2 * w[1] + tm3 * w[2];
                const simd_float2 level = z / simd_abs(tpp - mapping * dz);
                return getTextureColor(buffer, mapping, level);
            };
        } else { exit(999); }

        for (int y = ymin; y <= ymax; y++) {
            for (int x = xmin; x <= xmax; x++) {
                if (weight.w[0] >= 0 && weight.w[1] >= 0 && weight.w[2] >= 0) {
                    const float z = simd_dot(rvz, weight.w);
                    if (z > *pointers.dbuffer) {
                        *pointers.dbuffer = z;
                        const simd_float3 w = weight.w / z;
                        const simd_float3 point = -simd_fast_normalize(p1 * w[0] + p2 * w[1] + p3 * w[2]);
                        const simd_float3 normal = simd_fast_normalize(n1 * w[0] + n2 * w[1] + n3 * w[2]);
                        const simd_float3 halfway = simd_fast_normalize(point + normal);
                        const simd_float3 shadedColor = simd_dot(halfway, normal) * getColor(w, z);
//                        const simd_float3 shadedColor = getColor(w, z);
                        *pointers.pbuffer = RGB(shadedColor[0], shadedColor[1], shadedColor[2]);
                    }
                }
                weight.w += weight.dx;
                pointers.pbuffer++;
                pointers.dbuffer++;
            }
            weight.wy += weight.dy;
            weight.w = weight.wy;
            pointers.pbuffer += pointers.xDelta;
            pointers.dbuffer += pointers.xDelta;
        }
    }
}

}
