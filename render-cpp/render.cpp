#include <simd/simd.h>
#include <functional>
#include <dlfcn.h>
#include "render.hpp"

extern "C" {

#define RGB(r, g, b) (uint32_t)(((((uint8_t)(r) << 8) + (uint8_t)(g)) << 8) + (uint8_t)(b))
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
    color_attribute_t color_attribute;
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
    const uint32_t xDelta;
} pointers_t;

static struct {
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
    scene.attributes = (vertex_attribute_t *)malloc(2 * *count * sizeof(vertex_attribute_t));
    fread(scene.attributes, sizeof(vertex_attribute_t), *count, fp);
    scene.normals = (simd_float3 *)malloc(2 * *count * sizeof(simd_float3));

    fread(count, sizeof(uint64_t), 2, fp);
    scene.attribute_indices_count = *count;
    aligned_count = *count + (*count % 2);
    scene.attribute_indices = (uint64_t *)malloc(2 * aligned_count * sizeof(uint64_t));
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

    const simd_float2 size = simd_make_float2((float)pixel_data->width, (float)pixel_data->height);
    for (uint32_t i = 0; i < scene.vertex_count; i++) {
        const simd_float3 v = simd_mul(state.camera_matrix, scene.vertices[i]);
        scene.camera_vertices[i] = v;
        scene.raster_vertices[i] = simd_make_float3(v.x, -v.y, 0) * config.factor / -v.z + simd_make_float3(size / 2, -v.z);
    }
    for (uint32_t i = 0; i < scene.attributes_count; i++) {
        scene.normals[i] = simd_mul(state.camera_matrix, scene.attributes[i].normal);
    }
    
    uint64_t vertexIndicesCount = scene.vertex_indices_count;
    uint64_t vertexCount = scene.vertex_count;
    uint64_t attributeCount = scene.attributes_count;
    for (uint32_t index = 0; index < vertexIndicesCount; index += 3) {
        const uint64_t vi[3] = {scene.vertex_indices[index], scene.vertex_indices[index + 1], scene.vertex_indices[index + 2]};
        simd_float3 rv[3] = {scene.raster_vertices[vi[0]], scene.raster_vertices[vi[1]], scene.raster_vertices[vi[2]]};
        if (fmaxf(fmaxf(rv[0].z, rv[1].z), rv[2].z) <= config.near) { continue; }

        simd_float3 cv[3] = {scene.camera_vertices[vi[0]], scene.camera_vertices[vi[1]], scene.camera_vertices[vi[2]]};
        const uint64_t ai[3] = {scene.attribute_indices[index], scene.attribute_indices[index + 1], scene.attribute_indices[index + 2]};
        color_attribute_t ac[3] = {scene.attributes[ai[0]].color_attribute, scene.attributes[ai[1]].color_attribute, scene.attributes[ai[2]].color_attribute};
        simd_float3 n[3] = {scene.normals[ai[0]], scene.normals[ai[1]], scene.normals[ai[2]]};

        if (fmin(fmin(rv[0].z, rv[1].z), rv[2].z) < config.near) {
            simd_float3 cv_new[3];
            simd_float3 rv_new[3];
            color_attribute_t ac_new[3];
            simd_float3 n_new[3];
            uint32_t viCurrent = 0;
            uint32_t viNext = 0;
            uint32_t viPreceding = 0;
            bool newTriangle = false;
            for (uint32_t i = 0; i < 3; i++) {
                uint32_t iNext = (i + 1) % 3;
                if ((rv[i].z > config.near) == (rv[iNext].z > config.near)) {
                    viCurrent = i; viNext = iNext; viPreceding = (i + 2) % 3;
                    newTriangle = rv[i].z > config.near;
                } else {
                    float a = (config.near - rv[i].z) / (rv[iNext].z - rv[i].z);
                    simd_float3 v = cv[i] * (1 - a) + cv[iNext] * a;
                    cv_new[i] = v;
                    rv_new[i] = simd_make_float3(v.x, -v.y, 0) * config.factor / -v.z + simd_make_float3(size / 2, config.near);
                    disc_t disc = scene.attributes[ai[i]].disc;
                    if (disc == color) {
                        simd_float3 c1 = ac[i].color;
                        simd_float3 c2 = ac[iNext].color;
                        ac_new[i].color = c1 * (1 - a) + c2 * a;
                    } else if (disc == texture) {
                        texture_t t1 = ac[i].texture;
                        texture_t t2 = ac[iNext].texture;
                        ac_new[i].texture = { .index = t1.index, .uv = t1.uv * (1 - a) + t2.uv * a};
                    } else { exit(999); }
                    n_new[i] = n[i] * (1 - a) + n[iNext] * a;
                }
            }
            if (newTriangle) {
                cv[viPreceding] = cv_new[viNext];
                rv[viPreceding] = rv_new[viNext];
                ac[viPreceding] = ac_new[viNext];
                n[viPreceding] = n_new[viNext];
                uint64_t j = vertexCount;
                uint64_t k = attributeCount;
                scene.camera_vertices[j] = cv_new[viNext];
                scene.raster_vertices[j] = rv_new[viNext];
                scene.attributes[k].color_attribute = ac_new[viNext];
                scene.normals[k] = n_new[viNext];
                scene.camera_vertices[j + 1] = cv_new[viPreceding];
                scene.raster_vertices[j + 1] = rv_new[viPreceding];
                scene.attributes[k + 1].color_attribute = ac_new[viPreceding];
                scene.normals[k + 1] = n_new[viPreceding];
                scene.vertex_indices[vertexIndicesCount] = vi[viCurrent];
                scene.vertex_indices[vertexIndicesCount + 1] = j;
                scene.vertex_indices[vertexIndicesCount + 2] = j + 1;
                scene.attribute_indices[vertexIndicesCount] = ai[viCurrent];
                scene.attribute_indices[vertexIndicesCount + 1] = k;
                scene.attribute_indices[vertexIndicesCount + 2] = k + 1;
                vertexCount += 2;
                attributeCount += 2;
                vertexIndicesCount += 3;
            } else {
                cv[viCurrent] = cv_new[viPreceding];
                rv[viCurrent] = rv_new[viPreceding];
                ac[viCurrent] = ac_new[viPreceding];
                n[viCurrent] = n_new[viPreceding];
                cv[viNext] = cv_new[viNext];
                rv[viNext] = rv_new[viNext];
                ac[viNext] = ac_new[viNext];
                n[viNext] = n_new[viNext];
            }
        }
        const simd_float3 rvmax = simd_max(simd_max(rv[0], rv[1]), rv[2]);
        if (rvmax.x < 0 || rvmax.y < 0) { continue; }
        const simd_float3 rvmin = simd_min(simd_min(rv[0], rv[1]), rv[2]);
        if (rvmin.x >= size[0] || rvmin.y >= size[1]) { continue; }
            
        const float area = EDGE_FUNCTION(rv[0], rv[1], rv[2]);
        if (area < 10) { continue; }
        const float oneOverArea = 1 / area;
        const uint32_t xmin = (uint32_t)fmaxf(0, rvmin.x);
        const uint32_t xmax = (uint32_t)fmin(size[0] - 1, rvmax.x);
        const uint32_t ymin = (uint32_t)fmaxf(0, rvmin.y);
        const uint32_t ymax = (uint32_t)fmin(size[1] - 1, rvmax.y);
        const simd_float2 pStart = simd_make_float2((float)xmin + 0.5f, (float)ymin + 0.5f);
        const simd_float3 wstart = simd_make_float3(EDGE_FUNCTION(rv[1], rv[2], pStart), EDGE_FUNCTION(rv[2], rv[0], pStart), EDGE_FUNCTION(rv[0], rv[1], pStart)) * oneOverArea;
        weight_t weight = {
            .w = wstart, .wy = wstart,
            .dx = simd_make_float3(rv[1].y - rv[2].y, rv[2].y - rv[0].y, rv[0].y - rv[1].y) * oneOverArea,
            .dy = simd_make_float3(rv[2].x - rv[1].x, rv[0].x - rv[2].x, rv[1].x - rv[0].x) * oneOverArea };
        const uint32_t bufferStart = ymin * pixel_data->width + xmin;
        pointers_t pointers = {
            .pbuffer = pixel_data->buffer + bufferStart,
            .dbuffer = depth_buffer.buffer + bufferStart,
            .xDelta = pixel_data->width - xmax + xmin - 1,
        };
        
        const simd_float3 rvz = 1 / simd_make_float3(rv[0].z, rv[1].z, rv[2].z);
        const simd_float3 p[3] = {cv[0] * rvz[0], cv[1] * rvz[1], cv[2] * rvz[2]};
        n[0] *= rvz[0];
        n[1] *= rvz[1];
        n[2] *= rvz[2];
        std::function<simd_float3(simd_float3, float)> getColor;
        disc_t disc = scene.attributes[ai[0]].disc;
        if (disc == color) {
            const simd_float3 cc1 = ac[0].color * rvz[0];
            const simd_float3 cc2 = ac[1].color * rvz[1];
            const simd_float3 cc3 = ac[2].color * rvz[2];
            getColor = [cc1, cc2, cc3] (const simd_float3 w, const float z) { (void)z;return cc1 * w[0] + cc2 * w[1] + cc3 * w[2];};
        } else if (disc == texture) {
            uint32_t *buffer = texture_buffer.buffer + ((int32_t)ac[0].texture.index << 18);
            const simd_float2 tm1 = ac[0].texture.uv * rvz[0];
            const simd_float2 tm2 = ac[1].texture.uv * rvz[1];
            const simd_float2 tm3 = ac[2].texture.uv * rvz[2];
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

        for (uint32_t y = ymin; y <= ymax; y++) {
            for (uint32_t x = xmin; x <= xmax; x++) {
                if (weight.w[0] >= 0 && weight.w[1] >= 0 && weight.w[2] >= 0) {
                    const float z = simd_dot(rvz, weight.w);
                    if (z > *pointers.dbuffer) {
                        *pointers.dbuffer = z;
                        const simd_float3 w = weight.w / z;
                        const simd_float3 point = -simd_fast_normalize(p[0] * w[0] + p[1] * w[1] + p[2] * w[2]);
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
