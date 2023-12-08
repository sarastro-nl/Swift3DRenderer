import Foundation
import simd

private struct State {
    static var cameraPosition = simd_float3.zero
    static var cameraAxis = (x: simd_float3(1, 0, 0), y: simd_float3(0, 1, 0), z: simd_float3(0, 0, 1))
    static var cameraMatrix = matrix_identity_float4x4
    static var mouse = simd_float2.zero
}

private struct Scene {
    static var vertices: UnsafeMutablePointer<simd_float4> = .allocate(capacity: 0)
    static var vertexCount: Int = 0
    static var vertexIndices: UnsafeMutablePointer<Int> = .allocate(capacity: 0)
    static var vertexIndicesCount: Int = 0
    static var attributes: UnsafeMutablePointer<VertexAttribute> = .allocate(capacity: 0)
    static var attributesCount: Int = 0
    static var attributeIndices: UnsafeMutablePointer<Int> = .allocate(capacity: 0)
    static var attributeIndicesCount: Int = 0
    
    static var cameraVertices: UnsafeMutablePointer<simd_float3> = .allocate(capacity: 0)
    static var cameraVertexCount: Int = 0
    static var rasterVertices: UnsafeMutablePointer<simd_float3> = .allocate(capacity: 0)
    static var rasterVertexCount: Int = 0
    static var workingAttributes: UnsafeMutablePointer<VertexAttribute> = .allocate(capacity: 0)
}

private struct DepthBuffer {
    static var buffer: UnsafeMutablePointer<Float> = .allocate(capacity: 0)
    static var bufferSize: Int = 0
}

private struct Config {
    static let near: Float = 0.1
    static let fov = Float.pi / 5
    static let scale = Config.near * tan(Config.fov / 2)
    static var factor: Float = 1
    static let speed: Float = 0.1
    static let rotationSpeed: Float = 0.1
    static var backgroundColor = RGB(simd_float3(30, 30, 30))
    static var initialized = false
}

struct Texture {
    let index: Int
    let uv: simd_float2
}

enum ColorAttribute {
    case color(simd_float3)
    case texture(Texture)
}

struct VertexAttribute {
    var normal: simd_float4
    let colorAttribute: ColorAttribute
}

private struct Weight {
    static var w = simd_float3.zero
    static var wy = simd_float3.zero
    static var dx = simd_float3.zero
    static var dy = simd_float3.zero
}

private struct Pointers {
    static var pBuffer: UnsafeMutablePointer<UInt32> = .allocate(capacity: 0)
    static var dBuffer: UnsafeMutablePointer<Float> = .allocate(capacity: 0)
    static var xDelta = 0
}

private struct Textures {
    static var buffer: UnsafeMutablePointer<UInt32> = .allocate(capacity: 0)
    static var bufferSize: Int = 0
}

@inline(__always)
private func RGB(_ rgb: simd_float3) -> UInt32 {
    (UInt32(UInt8(rgb[0])) << 8 + UInt32(UInt8(rgb[1]))) << 8 + UInt32(UInt8(rgb[2]))
}

@inline(__always)
private func edgeFunction(_ v1: simd_float3, _ v2: simd_float3, _ v3: simd_float3) -> Float {
    (v3.x - v1.x) * (v1.y - v2.y) + (v3.y - v1.y) * (v2.x - v1.x)
}

@inline(__always)
private func nextPowerOfTwo(_ f: Float) -> Int {
    var i = Int(f) - 1
    i |= i >> 1
    i |= i >> 2
    i |= i >> 4
    return i + 1
}

@inline(__always)
private func getTextureColor(_ buffer: UnsafePointer<UInt32>, _ uv: simd_float2, _ level: simd_float2) -> simd_float3 {
    let levelX = nextPowerOfTwo(max(min(level.x, 256), 1))
    let levelY = nextPowerOfTwo(max(min(level.y, 256), 1))
    let x = Int(fmodf(uv.x, 1) * Float(levelX)) + 511 & ~(2 * levelX - 1)
    let y = Int(fmodf(uv.y, 1) * Float(levelY)) + 511 & ~(2 * levelY - 1)
    let rgb = (buffer + x + y << 9).pointee
    return simd_float3(Float(rgb >> 16), Float((rgb >> 8) & 255), Float(rgb & 255))
}

private func updateCamera(_ input: inout Input) {
    var changed = false
    if input.left > 0 || input.right > 0 || input.up > 0 || input.down > 0 {
        changed = true
        State.cameraPosition += Config.speed * ((input.right - input.left) * State.cameraAxis.x + (input.down - input.up) * State.cameraAxis.z)
    }
    if input.mouse != State.mouse {
        changed = true
        let z: simd_float3 = simd_fast_normalize((State.mouse.x - input.mouse.x) * State.cameraAxis.x +
                                                 (State.mouse.y - input.mouse.y) * State.cameraAxis.y +
                                                 (100 / Config.rotationSpeed)    * State.cameraAxis.z)
        let q = simd_quatf(from: State.cameraAxis.z, to: z)
        State.cameraAxis.x = simd_fast_normalize(simd_act(q, State.cameraAxis.x))
        State.cameraAxis.y = simd_fast_normalize(simd_act(q, State.cameraAxis.y))
        State.cameraAxis.z = z
        State.mouse = input.mouse
    }
    if changed {
        State.cameraMatrix = simd_float4x4(rows: [simd_float4(State.cameraAxis.x, -simd_dot(State.cameraAxis.x, State.cameraPosition)),
                                                  simd_float4(State.cameraAxis.y, -simd_dot(State.cameraAxis.y, State.cameraPosition)),
                                                  simd_float4(State.cameraAxis.z, -simd_dot(State.cameraAxis.z, State.cameraPosition)),
                                                  simd_float4.zero])
    }
}

func initialize() {
    guard let reader = InputStream(fileAtPath: Bundle.main.dataPath) else { fatalError() }
    reader.open()
    defer { reader.close() }

    let count: UnsafeMutablePointer<Int> = .allocate(capacity: 2)
    reader.read(count, maxLength: 16)
    Scene.vertexCount = count.pointee
    Scene.vertices = .allocate(capacity: Scene.vertexCount)
    reader.read(Scene.vertices, maxLength: count.pointee * MemoryLayout<simd_float4>.stride)
    Scene.cameraVertices = .allocate(capacity: count.pointee)
    Scene.rasterVertices = .allocate(capacity: count.pointee)

    reader.read(count, maxLength: 16)
    Scene.vertexIndicesCount = count.pointee
    var alignedCount = Scene.vertexIndicesCount + (Scene.vertexIndicesCount % 2 == 0 ? 0 : 1)
    Scene.vertexIndices = .allocate(capacity: alignedCount)
    reader.read(Scene.vertexIndices, maxLength: alignedCount * MemoryLayout<Int>.stride)
    
    reader.read(count, maxLength: 16)
    Scene.attributesCount = count.pointee
    Scene.attributes = .allocate(capacity: Scene.attributesCount)
    reader.read(Scene.attributes, maxLength: Scene.attributesCount * MemoryLayout<VertexAttribute>.stride)
    Scene.workingAttributes = .allocate(capacity: Scene.attributesCount)
    
    reader.read(count, maxLength: 16)
    Scene.attributeIndicesCount = count.pointee
    alignedCount = Scene.attributeIndicesCount + (Scene.attributeIndicesCount % 2 == 0 ? 0 : 1)
    Scene.attributeIndices = .allocate(capacity: alignedCount)
    reader.read(Scene.attributeIndices, maxLength: alignedCount * MemoryLayout<Int>.stride)

    reader.read(count, maxLength: 16)
    Textures.bufferSize = count.pointee
    Textures.buffer = .allocate(capacity: Textures.bufferSize)
    reader.read(Textures.buffer, maxLength: Textures.bufferSize)
}

func updateAndRender(_ pixelData: inout PixelData, _ input: inout Input) {
    if !Config.initialized {
        Config.initialized = true
        initialize()
    }
    updateCamera(&input)

    let depthBufferSize = Int(pixelData.width * pixelData.height) * MemoryLayout<Float>.size
    if DepthBuffer.bufferSize != depthBufferSize {
        DepthBuffer.bufferSize = depthBufferSize
        DepthBuffer.buffer = unsafeBitCast(realloc(DepthBuffer.buffer, depthBufferSize), to: UnsafeMutablePointer<Float>.self)
        Config.factor = Config.near * Float(pixelData.height) / (2 * Config.scale)
    }
    memset(DepthBuffer.buffer, 0, depthBufferSize)
    memset_pattern4(pixelData.buffer, &Config.backgroundColor, Int(pixelData.bufferSize))

    let screenSize = simd_float2(Float(pixelData.width), Float(pixelData.height))
    for (i, vertex) in UnsafeBufferPointer(start: Scene.vertices, count: Scene.vertexCount).enumerated() {
        Scene.cameraVertices[i] = simd_make_float3(simd_mul(State.cameraMatrix, vertex))
    }
    for (i, vertex) in UnsafeBufferPointer(start: Scene.cameraVertices, count: Scene.vertexCount).enumerated() {
        if vertex.z > -Config.near {
            Scene.rasterVertices[i] = simd_float3.zero
        } else {
            Scene.rasterVertices[i] = simd_float3(vertex.x, -vertex.y, 0) * Config.factor / -vertex.z + simd_float3(screenSize / 2, -vertex.z)
        }
    }
    memcpy(Scene.workingAttributes, Scene.attributes, Scene.attributesCount * MemoryLayout<VertexAttribute>.stride)
    for (i, attribute) in UnsafeBufferPointer(start: Scene.attributes, count: Scene.attributesCount).enumerated() {
        Scene.workingAttributes[i].normal = simd_mul(State.cameraMatrix, attribute.normal)
    }
    for i in stride(from: 0, to: Scene.vertexIndicesCount, by: 3) {
        let (vi1, vi2, vi3) = (Scene.vertexIndices[i], Scene.vertexIndices[i + 1], Scene.vertexIndices[i + 2])
        let (rv1, rv2, rv3) = (Scene.rasterVertices[vi1], Scene.rasterVertices[vi2], Scene.rasterVertices[vi3])
        let rvmin = simd_min(simd_min(rv1, rv2), rv3)
        if rvmin.x >= screenSize[0] || rvmin.y >= screenSize[1] || rvmin.z < Config.near { continue }
        let rvmax = simd_max(simd_max(rv1, rv2), rv3)
        if rvmax.x < 0 || rvmax.y < 0 { continue }
        let area = edgeFunction(rv1, rv2, rv3)
        if area < 10 { continue }
        let oneOverArea = 1 / area
        let xmin = max(0, Int(rvmin.x))
        let xmax = min(Int(pixelData.width) - 1, Int(rvmax.x))
        let ymin = max(0, Int(rvmin.y))
        let ymax = min(Int(pixelData.height) - 1, Int(rvmax.y))
        let pStart = simd_float3(Float(xmin) + 0.5, Float(ymin) + 0.5, 0)
        let wStart = simd_float3(edgeFunction(rv2, rv3, pStart), edgeFunction(rv3, rv1, pStart), edgeFunction(rv1, rv2, pStart)) * oneOverArea
        Weight.w = wStart
        Weight.wy = wStart
        Weight.dx = simd_float3(rv2.y - rv3.y, rv3.y - rv1.y, rv1.y - rv2.y) * oneOverArea
        Weight.dy = simd_float3(rv3.x - rv2.x, rv1.x - rv3.x, rv2.x - rv1.x) * oneOverArea
        let bufferStart = ymin * Int(pixelData.width) + xmin
        Pointers.pBuffer = pixelData.buffer + bufferStart
        Pointers.dBuffer = DepthBuffer.buffer + bufferStart
        Pointers.xDelta = Int(pixelData.width) - xmax + xmin - 1
        
        let (a1, a2, a3) = (Scene.workingAttributes[Scene.attributeIndices[i]],
                            Scene.workingAttributes[Scene.attributeIndices[i + 1]],
                            Scene.workingAttributes[Scene.attributeIndices[i + 2]])
        let rvz = 1 / simd_float3(rv1.z, rv2.z, rv3.z)
        let n1 = simd_make_float3(a1.normal * rvz[0])
        let n2 = simd_make_float3(a2.normal * rvz[1])
        let n3 = simd_make_float3(a3.normal * rvz[2])
        let p1 = Scene.cameraVertices[vi1] * rvz[0]
        let p2 = Scene.cameraVertices[vi2] * rvz[1]
        let p3 = Scene.cameraVertices[vi3] * rvz[2]
        let getColor: (simd_float3, Float) -> simd_float3
        if case .color(let c1) = a1.colorAttribute, case .color(let c2) = a2.colorAttribute, case .color(let c3) = a3.colorAttribute {
            let cc1 = c1 * rvz[0]
            let cc2 = c2 * rvz[1]
            let cc3 = c3 * rvz[2]
            getColor = { w, _ in cc1 * w[0] + cc2 * w[1] + cc3 * w[2] }
        } else if case .texture(let t1) = a1.colorAttribute, case .texture(let t2) = a2.colorAttribute, case .texture(let t3) = a3.colorAttribute {
            let buffer = Textures.buffer + t1.index << 18
            let tm1 = t1.uv * rvz[0]
            let tm2 = t2.uv * rvz[1]
            let tm3 = t3.uv * rvz[2]
            let tpp: simd_float2 = 1 / simd_abs(tm1 * simd_float2(Weight.dx[0], Weight.dy[0]) +
                                                tm2 * simd_float2(Weight.dx[1], Weight.dy[1]) +
                                                tm3 * simd_float2(Weight.dx[2], Weight.dy[2]))
            getColor = { w, z in getTextureColor(buffer, tm1 * w[0] + tm2 * w[1] + tm3 * w[2], tpp * z) }
        } else { fatalError() }
        
        for _ in ymin...ymax {
            for _ in xmin...xmax {
                if Weight.w[0] >= 0 && Weight.w[1] >= 0 && Weight.w[2] >= 0 {
                    let z = simd_dot(rvz, Weight.w)
                    if z > Pointers.dBuffer.pointee {
                        Pointers.dBuffer.pointee = z
                        let w = Weight.w / z
                        let point = -simd_fast_normalize(p1 * w[0] + p2 * w[1] + p3 * w[2])
                        let normal = simd_fast_normalize(n1 * w[0] + n2 * w[1] + n3 * w[2])
                        let halfway = simd_fast_normalize(point + normal)
                        let shadedColor = simd_dot(halfway, normal) * getColor(w, z)
//                        let shadedColor = getColor(w, z)
                        Pointers.pBuffer.pointee = RGB(shadedColor)
                    }
                }
                Weight.w += Weight.dx
                Pointers.pBuffer += 1
                Pointers.dBuffer += 1
            }
            Weight.wy += Weight.dy
            Weight.w = Weight.wy
            Pointers.pBuffer += Pointers.xDelta
            Pointers.dBuffer += Pointers.xDelta
        }
    }
}
