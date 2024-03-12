#include <simd/simd.h>
#include <functional>
#include <dlfcn.h>
#include "render.hpp"

extern "C" {
#include <immintrin.h>

#define RGB(r, g, b) (uint32_t)(((((uint8_t)(r) << 8) + (uint8_t)(g)) << 8) + (uint8_t)(b))
#define EDGE_FUNCTION(a, b, c) ((c.x - a.x) * (a.y - b.y) + (c.y - a.y) * (b.x - a.x))

typedef struct {
    uint32_t index;
    simd_float2 uv;
} texture_t;

typedef enum { color = 0, texture } disc_t;

typedef struct {
    union {
        simd_float3 color;
        texture_t texture;
    } u;
    disc_t disc;
} color_attribute_t;

typedef struct {
    simd_float3 cv;
    simd_float3 rv;
    color_attribute_t ca;
    simd_float3 n;
} data_t;

typedef struct {
    const simd_float4 normal;
    color_attribute_t ca;
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
    const uint32_t xDelta;
} pointers_t;

static struct {
    simd_float3 camera_position;
    struct {
        simd_float3 x;
        simd_float3 y;
        simd_float3 z;
    } camera_axis;
    simd_float4x3 camera_matrix;
    simd_float2 mouse;
} state = {
    .camera_position = simd_make_float3(0, 0, 0),
    .camera_axis = { .x = simd_make_float3(1, 0, 0), .y = simd_make_float3(0, 1, 0), .z = simd_make_float3(0, 0, 1)},
    .camera_matrix = simd_matrix_from_rows(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(0, 0, 1, 0)),
    .mouse = simd_make_float2(0, 0),
};

static struct {
    float *buffer;
    uint32_t buffer_size;
} depth_buffer = {
    .buffer = NULL,
    .buffer_size = 0,
};

static struct {
    uint32_t *buffer;
} texture_buffer = {
    .buffer = NULL,
};

static struct {
    const float near;
    const float fov;
    const float scale;
    float factor;
    const float speed;
    const float rotation_speed;
    const uint32_t background_color;
} config = {
    .near = 0.1f,
    .fov = (float)M_PI / 5.f,
    .scale = config.near * tan(config.fov / 2),
    .factor = 1,
    .speed = 0.1f,
    .rotation_speed = 0.3f,
    .background_color = RGB(30, 30, 30),
};

static struct {
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
    color_attribute_t *color_attributes;
    simd_float3 *normals;
} scene;

__attribute__((always_inline))
uint32_t nextPowerOfTwo(uint32_t i) {
    i--;
    i |= i >> 1;
    i |= i >> 2;
    i |= i >> 4;
    return i + 1;
}

__attribute__((always_inline))
simd_float3 getTextureColor(uint32_t *buffer, simd_float2 uv, simd_float2 level) {
    uint32_t levelX = nextPowerOfTwo((uint32_t)fmaxf(fmin(level.x, 256.f), 1.f));
    uint32_t levelY = nextPowerOfTwo((uint32_t)fmaxf(fmin(level.y, 256.f), 1.f));
    uint32_t x = (uint32_t)(fmodf(uv.x, 1) * levelX) + (511 & ~(2 * levelX - 1));
    uint32_t y = (uint32_t)(fmodf(uv.y, 1) * levelY) + (511 & ~(2 * levelY - 1));
    uint32_t rgb = *(buffer + x + (y << 9));
    return simd_make_float3((float)(rgb >> 16), (float)((rgb >> 8) & 255), (float)(rgb & 255));
}

void update_camera(const Input *input, const bool force_update = false) {
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
    if (changed || force_update) {
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
    scene.camera_vertices = (simd_float3 *)malloc(2 * *count * sizeof(simd_float3));
    scene.raster_vertices = (simd_float3 *)malloc(2 * *count * sizeof(simd_float3));
    
    fread(count, sizeof(uint64_t), 2, fp);
    scene.vertex_indices_count = *count;
    uint64_t aligned_count = *count + (*count % 2);
    scene.vertex_indices = (uint64_t *)malloc(2 * aligned_count * sizeof(uint64_t));
    fread(scene.vertex_indices, sizeof(uint64_t), aligned_count, fp);
    
    fread(count, sizeof(uint64_t), 2, fp);
    scene.attributes_count = *count;
    scene.attributes = (vertex_attribute_t *)malloc(*count * sizeof(vertex_attribute_t));
    fread(scene.attributes, sizeof(vertex_attribute_t), *count, fp);
    scene.color_attributes = (color_attribute_t *)malloc(2 * *count * sizeof(color_attribute_t));
    scene.normals = (simd_float3 *)malloc(2 * *count * sizeof(simd_float3));
    for (int i = 0; i < scene.attributes_count; i++) {
        scene.color_attributes[i] = scene.attributes[i].ca;
    }
    
    fread(count, sizeof(uint64_t), 2, fp);
    scene.attribute_indices_count = *count;
    aligned_count = *count + (*count % 2);
    scene.attribute_indices = (uint64_t *)malloc(2 * aligned_count * sizeof(uint64_t));
    fread(scene.attribute_indices, sizeof(uint64_t), aligned_count, fp);

    fread(count, sizeof(uint64_t), 2, fp);
    texture_buffer.buffer = (uint32_t *)malloc(*count * sizeof(uint32_t));
    fread(texture_buffer.buffer, sizeof(uint32_t), *count, fp);
}

void clip(data_t *data, uint64_t *v_count, uint64_t *a_count, uint64_t *vi_count, const uint64_t *vi, const uint64_t *ai, const simd_float2 *screen_size) {
    data_t data_new[3];
    uint64_t vi_current = 0, vi_next = 0, vi_preceding = 0;
    bool new_triangle = false;
    for (uint32_t i = 0; i < 3; i++) {
        uint32_t i_next = (i + 1) % 3;
        if ((data[i].rv.z > config.near) == (data[i_next].rv.z > config.near)) {
            vi_current = i; vi_next = i_next; vi_preceding = (i + 2) % 3;
            new_triangle = data[i].rv.z > config.near;
        } else {
            float a = (config.near - data[i].rv.z) / (data[i_next].rv.z - data[i].rv.z);
            simd_float3 cv = data[i].cv * (1 - a) + data[i_next].cv * a;
            simd_float3 rv = simd_make_float3(cv.x, -cv.y, 0) * config.factor / config.near + simd_make_float3(*screen_size / 2, config.near);
            color_attribute_t ca = {.disc = data[0].ca.disc};
            switch (ca.disc) {
                case color:
                    ca.u.color = data[i].ca.u.color * (1 - a) + data[i_next].ca.u.color * a;
                    break;
                case texture:
                    texture_t t1 = data[i].ca.u.texture;
                    texture_t t2 = data[i_next].ca.u.texture;
                    ca.u.texture = { .index = t1.index, .uv = t1.uv * (1 - a) + t2.uv * a};
            }
            simd_float3 n = data[i].n * (1 - a) + data[i_next].n * a;
            data_new[i] = {cv, rv, ca, n};
        }
    }
    if (new_triangle) {
        data[vi_preceding] = data_new[vi_next];
        scene.camera_vertices[*v_count] = data_new[vi_next].cv;
        scene.raster_vertices[*v_count] = data_new[vi_next].rv;
        scene.color_attributes[*a_count] = data_new[vi_next].ca;
        scene.normals[*a_count] = data_new[vi_next].n;
        scene.camera_vertices[*v_count + 1] = data_new[vi_preceding].cv;
        scene.raster_vertices[*v_count + 1] = data_new[vi_preceding].rv;
        scene.color_attributes[*a_count + 1] = data_new[vi_preceding].ca;
        scene.normals[*a_count + 1] = data_new[vi_preceding].n;
        scene.vertex_indices[*vi_count] = vi[vi_current];
        scene.vertex_indices[*vi_count + 1] = *v_count;
        scene.vertex_indices[*vi_count + 2] = *v_count + 1;
        scene.attribute_indices[*vi_count] = ai[vi_current];
        scene.attribute_indices[*vi_count + 1] = *a_count;
        scene.attribute_indices[*vi_count + 2] = *a_count + 1;
        *v_count += 2;
        *a_count += 2;
        *vi_count += 3;
    } else {
        data[vi_current] = data_new[vi_preceding];
        data[vi_next] = data_new[vi_next];
    }
}

static simd_float2 extracted(const PixelData *pixel_data) {
    const simd_float2 size = simd_make_float2((float)pixel_data->width, (float)pixel_data->height);
    return size;
}

__attribute__((visibility("default")))
void updateAndRender(const PixelData *pixel_data, const Input *input) {
    static bool initialized = false;
    if (!initialized) {
        initialized = true;
        initialize();
        update_camera(input, true);
    } else {
        update_camera(input);
    }
    
    const uint32_t depth_buffer_size = pixel_data->width * pixel_data->height * sizeof(float);
    if (depth_buffer.buffer_size != depth_buffer_size) {
        depth_buffer.buffer_size = depth_buffer_size;
        depth_buffer.buffer = (float *)realloc(depth_buffer.buffer, depth_buffer_size);
        config.factor = config.near * pixel_data->height / (2 * config.scale);
    }
    memset(depth_buffer.buffer, 0, depth_buffer.buffer_size);
    memset_pattern4(pixel_data->buffer, &config.background_color, pixel_data->bufferSize);

    const simd_float2 screen_size = extracted(pixel_data);
    for (uint32_t i = 0; i < scene.vertex_count; i++) {
        const simd_float3 v = simd_mul(state.camera_matrix, scene.vertices[i]);
        scene.camera_vertices[i] = v;
        scene.raster_vertices[i] = simd_make_float3(v.x, -v.y, 0) * config.factor / -v.z + simd_make_float3(screen_size / 2, -v.z);
    }
    for (uint32_t i = 0; i < scene.attributes_count; i++) {
        scene.normals[i] = simd_mul(state.camera_matrix, scene.attributes[i].normal);
    }
    
    uint64_t vertex_indices_count = scene.vertex_indices_count;
    uint64_t vertex_count = scene.vertex_count;
    uint64_t attribute_count = scene.attributes_count;
    for (uint32_t index = 0; index < vertex_indices_count; index += 3) {
        const uint64_t vi[3] = {scene.vertex_indices[index], scene.vertex_indices[index + 1], scene.vertex_indices[index + 2]};
        const uint64_t ai[3] = {scene.attribute_indices[index], scene.attribute_indices[index + 1], scene.attribute_indices[index + 2]};
        data_t data[3] = {
            {scene.camera_vertices[vi[0]], scene.raster_vertices[vi[0]], scene.color_attributes[ai[0]], scene.normals[ai[0]]},
            {scene.camera_vertices[vi[1]], scene.raster_vertices[vi[1]], scene.color_attributes[ai[1]], scene.normals[ai[1]]},
            {scene.camera_vertices[vi[2]], scene.raster_vertices[vi[2]], scene.color_attributes[ai[2]], scene.normals[ai[2]]},
        };
        
        if (fmaxf(fmaxf(data[0].rv.z, data[1].rv.z), data[2].rv.z) <= config.near) { continue; }
        
        if (fmin(fmin(data[0].rv.z, data[1].rv.z), data[2].rv.z) < config.near) {
            clip(data, &vertex_count, &attribute_count, &vertex_indices_count, vi, ai, &screen_size);
        }
        const simd_float3 rvmax = simd_max(simd_max(data[0].rv, data[1].rv), data[2].rv);
        if (rvmax.x < 0 || rvmax.y < 0) { continue; }
        const simd_float3 rvmin = simd_min(simd_min(data[0].rv, data[1].rv), data[2].rv);
        if (rvmin.x >= screen_size[0] || rvmin.y >= screen_size[1]) { continue; }
            
        const float area = EDGE_FUNCTION(data[0].rv, data[1].rv, data[2].rv);
        if (area < 10) { continue; } // too small to waiste time rendering it
        const float oneOverArea = 1 / area;
        const uint32_t xmin = (uint32_t)fmaxf(0, rvmin.x);
        const uint32_t xmax = (uint32_t)fmin(screen_size[0] - 1, rvmax.x);
        const uint32_t ymin = (uint32_t)fmaxf(0, rvmin.y);
        const uint32_t ymax = (uint32_t)fmin(screen_size[1] - 1, rvmax.y);
        const simd_float2 pStart = simd_make_float2((float)xmin + 0.5f, (float)ymin + 0.5f);
        const simd_float3 wstart = simd_make_float3(EDGE_FUNCTION(data[1].rv, data[2].rv, pStart), EDGE_FUNCTION(data[2].rv, data[0].rv, pStart), EDGE_FUNCTION(data[0].rv, data[1].rv, pStart)) * oneOverArea;
        weight_t weight = {
            .w = wstart, .wy = wstart,
            .dx = simd_make_float3(data[1].rv.y - data[2].rv.y, data[2].rv.y - data[0].rv.y, data[0].rv.y - data[1].rv.y) * oneOverArea,
            .dy = simd_make_float3(data[2].rv.x - data[1].rv.x, data[0].rv.x - data[2].rv.x, data[1].rv.x - data[0].rv.x) * oneOverArea };
        const uint32_t bufferStart = ymin * pixel_data->width + xmin;
        pointers_t pointers = {
            .pbuffer = pixel_data->buffer + bufferStart,
            .dbuffer = depth_buffer.buffer + bufferStart,
            .xDelta = pixel_data->width - xmax + xmin - 1,
        };
        
        const simd_float3 rvz = 1 / simd_make_float3(data[0].rv.z, data[1].rv.z, data[2].rv.z);
        const simd_float3 cv[3] = {data[0].cv * rvz[0], data[1].cv * rvz[1], data[2].cv * rvz[2]};
        const simd_float3 n[3] = {data[0].n * rvz[0], data[1].n * rvz[1], data[2].n * rvz[2]};
        std::function<simd_float3(simd_float3, float)> getColor;
        switch (data[0].ca.disc) {
            case color: {
                const simd_float3 cc[3] = {data[0].ca.u.color * rvz[0], data[1].ca.u.color * rvz[1], data[2].ca.u.color * rvz[2]};
                getColor = [cc] (const simd_float3 w, const float z) { (void)z;return cc[0] * w[0] + cc[1] * w[1] + cc[2] * w[2];};
                break;
            }
            case texture: {
                uint32_t *buffer = texture_buffer.buffer + ((int32_t)data[0].ca.u.texture.index << 18); // jump to right texture image
                const simd_float2 uv[3] = {data[0].ca.u.texture.uv * rvz[0], data[1].ca.u.texture.uv * rvz[1], data[2].ca.u.texture.uv * rvz[2]};
                const simd_float2 dz = simd_make_float2(simd_dot(rvz, weight.dx), simd_dot(rvz, weight.dy));
                const simd_float2 tpp = (uv[0] * simd_make_float2(weight.dx[0], weight.dy[0]) +
                                         uv[1] * simd_make_float2(weight.dx[1], weight.dy[1]) +
                                         uv[2] * simd_make_float2(weight.dx[2], weight.dy[2]));
                getColor = [buffer, uv, dz, tpp] (const simd_float3 w, const float z) {
                    const simd_float2 mapping = uv[0] * w[0] + uv[1] * w[1] + uv[2] * w[2];
                    const simd_float2 level = z / simd_abs(tpp - mapping * dz);
                    return getTextureColor(buffer, mapping, level);
                };
            }
        }
        for (uint32_t y = ymin; y <= ymax; y++) {
            for (uint32_t x = xmin; x <= xmax; x++) {
                if (weight.w[0] >= 0 && weight.w[1] >= 0 && weight.w[2] >= 0) {
                    const float z = simd_dot(rvz, weight.w);
                    if (z > *pointers.dbuffer) {
                        *pointers.dbuffer = z;
                        const simd_float3 w = weight.w / z;
                        const simd_float3 point = -simd_fast_normalize(cv[0] * w[0] + cv[1] * w[1] + cv[2] * w[2]);
                        const simd_float3 normal = simd_fast_normalize(n[0] * w[0] + n[1] * w[1] + n[2] * w[2]);
                        const simd_float3 halfway = simd_fast_normalize(point + normal);
                        const simd_float3 shadedColor = simd_dot(halfway, normal) * getColor(w, z);
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
