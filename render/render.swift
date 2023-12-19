import Foundation
import simd

private struct State {
    static var cameraPosition = simd_float3.zero
    static var cameraAxis = (x: simd_float3(1, 0, 0), y: simd_float3(0, 1, 0), z: simd_float3(0, 0, 1))
    static var cameraMatrix = simd_float4x3(diagonal: simd_float3.one)
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
    static var rasterVertices: UnsafeMutablePointer<simd_float3> = .allocate(capacity: 0)
    static var normals: UnsafeMutablePointer<simd_float3> = .allocate(capacity: 0)
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
    static let rotationSpeed: Float = 0.3
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
    let normal: simd_float4
    var colorAttribute: ColorAttribute
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
private func nextPowerOfTwo(_ i: Float) -> Int {
    var i = Int(i) - 1
    i |= i >> 1
    i |= i >> 2
    i |= i >> 4
    return i + 1
}

@inline(__always)
private func getTextureColor(_ buffer: UnsafePointer<UInt32>, _ uv: simd_float2, _ level: simd_float2) -> simd_float3 {
    let levelX = nextPowerOfTwo(fmax(fmin(level.x, 256), 1))
    let levelY = nextPowerOfTwo(fmax(fmin(level.y, 256), 1))
    let x = Int(fmodf(uv.x, 1) * Float(levelX)) + 511 & ~(2 * levelX - 1)
    let y = Int(fmodf(uv.y, 1) * Float(levelY)) + 511 & ~(2 * levelY - 1)
    let rgb = (buffer + x + y << 9).pointee
    return simd_float3(Float(rgb >> 16), Float((rgb >> 8) & 255), Float(rgb & 255))
}

private func updateCamera(_ input: inout Input, _ forceUpdate: Bool = false) {
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
    if changed || forceUpdate {
        State.cameraMatrix = simd_float4x3(rows: [simd_float4(State.cameraAxis.x, -simd_dot(State.cameraAxis.x, State.cameraPosition)),
                                                  simd_float4(State.cameraAxis.y, -simd_dot(State.cameraAxis.y, State.cameraPosition)),
                                                  simd_float4(State.cameraAxis.z, -simd_dot(State.cameraAxis.z, State.cameraPosition))])
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
    Scene.cameraVertices = .allocate(capacity: 2 * count.pointee)
    Scene.rasterVertices = .allocate(capacity: 2 * count.pointee)

    reader.read(count, maxLength: 16)
    Scene.vertexIndicesCount = count.pointee
    var alignedCount = Scene.vertexIndicesCount + Scene.vertexIndicesCount % 2
    Scene.vertexIndices = .allocate(capacity: 2 * alignedCount)
    reader.read(Scene.vertexIndices, maxLength: alignedCount * MemoryLayout<Int>.stride)
    
    reader.read(count, maxLength: 16)
    Scene.attributesCount = count.pointee
    Scene.attributes = .allocate(capacity: 2 * Scene.attributesCount)
    reader.read(Scene.attributes, maxLength: Scene.attributesCount * MemoryLayout<VertexAttribute>.stride)
    Scene.normals = .allocate(capacity: 2 * Scene.attributesCount)
    
    reader.read(count, maxLength: 16)
    Scene.attributeIndicesCount = count.pointee
    alignedCount = Scene.attributeIndicesCount + Scene.attributeIndicesCount % 2
    Scene.attributeIndices = .allocate(capacity: 2 * alignedCount)
    reader.read(Scene.attributeIndices, maxLength: alignedCount * MemoryLayout<Int>.stride)

    reader.read(count, maxLength: 16)
    Textures.buffer = .allocate(capacity: count.pointee)
    reader.read(Textures.buffer, maxLength: count.pointee * MemoryLayout<UInt32>.stride)
}

func updateAndRender(_ pixelData: inout PixelData, _ input: inout Input) {
    if !Config.initialized {
        Config.initialized = true
        initialize()
        updateCamera(&input, true)
    } else {
        updateCamera(&input)
    }

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
        let v = simd_mul(State.cameraMatrix, vertex)
        Scene.cameraVertices[i] = v
        Scene.rasterVertices[i] = simd_float3(v.x, -v.y, 0) * Config.factor / -v.z + simd_float3(screenSize / 2, -v.z)
    }
    for (i, attribute) in UnsafeBufferPointer(start: Scene.attributes, count: Scene.attributesCount).enumerated() {
        Scene.normals[i] = simd_mul(State.cameraMatrix, attribute.normal)
    }
    var index = 0
    var vertexIndicesCount = Scene.vertexIndicesCount
    var vertexCount = Scene.vertexCount
    var attributeCount = Scene.attributesCount
    while index < vertexIndicesCount {
        defer { index += 3 }
        let vi = [Scene.vertexIndices[index], Scene.vertexIndices[index + 1], Scene.vertexIndices[index + 2]]
        var rv = [Scene.rasterVertices[vi[0]], Scene.rasterVertices[vi[1]], Scene.rasterVertices[vi[2]]]
        if max(max(rv[0].z, rv[1].z), rv[2].z) <= Config.near { continue }

        var cv = [Scene.cameraVertices[vi[0]], Scene.cameraVertices[vi[1]], Scene.cameraVertices[vi[2]]]
        let ai = [Scene.attributeIndices[index], Scene.attributeIndices[index + 1], Scene.attributeIndices[index + 2]]
        var ac = [Scene.attributes[ai[0]].colorAttribute, Scene.attributes[ai[1]].colorAttribute, Scene.attributes[ai[2]].colorAttribute]
        var n = [Scene.normals[ai[0]], Scene.normals[ai[1]], Scene.normals[ai[2]]]
        if min(min(rv[0].z, rv[1].z), rv[2].z) < Config.near {
            var cvNew = Array(repeating: simd_float3.zero, count: 3)
            var rvNew = Array(repeating: simd_float3.zero, count: 3)
            var acNew = Array(repeating: ColorAttribute.color(simd_float3.zero), count: 3)
            var nNew = Array(repeating: simd_float3.zero, count: 3)
            var viCurrent = 0
            var viNext = 0
            var viPreceding = 0
            var newTriangle = false
            for i in 0..<3 {
                let iNext = (i + 1) % 3
                if (rv[i].z > Config.near) == (rv[iNext].z > Config.near) {
                    viCurrent = i; viNext = iNext; viPreceding = (i + 2) % 3
                    newTriangle = rv[i].z > Config.near
                } else {
                    let a = (Config.near - rv[i].z) / (rv[iNext].z - rv[i].z)
                    let v = cv[i] * (1 - a) + cv[iNext] * a
                    cvNew[i] = v
                    rvNew[i] = simd_float3(v.x, -v.y, 0) * Config.factor / -v.z + simd_float3(screenSize / 2, Config.near)
                    if case .color(let c1) = ac[i], case .color(let c2) = ac[iNext] {
                        acNew[i] = .color(c1 * (1 - a) + c2 * a)
                    } else if case .texture(let t1) = ac[i], case .texture(let t2) = ac[iNext] {
                        acNew[i] = .texture(Texture(index: t1.index, uv: t1.uv * (1 - a) + t2.uv * a))
                    }
                    nNew[i] = n[i] * (1 - a) + n[iNext] * a
                }
            }
            if newTriangle {
                cv[viPreceding] = cvNew[viNext]
                rv[viPreceding] = rvNew[viNext]
                ac[viPreceding] = acNew[viNext]
                n[viPreceding] = nNew[viNext]
                let j = vertexCount
                let k = attributeCount
                Scene.cameraVertices[j] = cvNew[viNext]
                Scene.rasterVertices[j] = rvNew[viNext]
                Scene.attributes[k].colorAttribute = acNew[viNext]
                Scene.normals[k] = nNew[viNext]
                Scene.cameraVertices[j + 1] = cvNew[viPreceding]
                Scene.rasterVertices[j + 1] = rvNew[viPreceding]
                Scene.attributes[k + 1].colorAttribute = acNew[viPreceding]
                Scene.normals[k + 1] = nNew[viPreceding]
                Scene.vertexIndices[vertexIndicesCount] = vi[viCurrent]
                Scene.vertexIndices[vertexIndicesCount + 1] = j
                Scene.vertexIndices[vertexIndicesCount + 2] = j + 1
                Scene.attributeIndices[vertexIndicesCount] = ai[viCurrent]
                Scene.attributeIndices[vertexIndicesCount + 1] = k
                Scene.attributeIndices[vertexIndicesCount + 2] = k + 1
                vertexCount += 2
                attributeCount += 2
                vertexIndicesCount += 3
            } else {
                cv[viCurrent] = cvNew[viPreceding]
                rv[viCurrent] = rvNew[viPreceding]
                ac[viCurrent] = acNew[viPreceding]
                n[viCurrent] = nNew[viPreceding]
                cv[viNext] = cvNew[viNext]
                rv[viNext] = rvNew[viNext]
                ac[viNext] = acNew[viNext]
                n[viNext] = nNew[viNext]
            }
        }
        let rvmax = simd_max(simd_max(rv[0], rv[1]), rv[2])
        if rvmax.x < 0 || rvmax.y < 0 { continue }
        let rvmin = simd_min(simd_min(rv[0], rv[1]), rv[2])
        if rvmin.x >= screenSize[0] || rvmin.y >= screenSize[1] { continue }

        let area = edgeFunction(rv[0], rv[1], rv[2])
        if area < 10 { continue }
        let oneOverArea = 1 / area
        let xmin = Int(fmax(0, rvmin.x))
        let xmax = Int(fmin(screenSize[0] - 1, rvmax.x))
        let ymin = Int(fmax(0, rvmin.y))
        let ymax = Int(fmin(screenSize[1] - 1, rvmax.y))
        let pStart = simd_float3(Float(xmin) + 0.5, Float(ymin) + 0.5, 0)
        let wStart = simd_float3(edgeFunction(rv[1], rv[2], pStart), edgeFunction(rv[2], rv[0], pStart), edgeFunction(rv[0], rv[1], pStart)) * oneOverArea
        Weight.w = wStart
        Weight.wy = wStart
        Weight.dx = simd_float3(rv[1].y - rv[2].y, rv[2].y - rv[0].y, rv[0].y - rv[1].y) * oneOverArea
        Weight.dy = simd_float3(rv[2].x - rv[1].x, rv[0].x - rv[2].x, rv[1].x - rv[0].x) * oneOverArea
        let bufferStart = ymin * Int(pixelData.width) + xmin
        Pointers.pBuffer = pixelData.buffer + bufferStart
        Pointers.dBuffer = DepthBuffer.buffer + bufferStart
        Pointers.xDelta = Int(pixelData.width) - xmax + xmin - 1
        
        let rvz = 1 / simd_float3(rv[0].z, rv[1].z, rv[2].z)
        let p = [cv[0] * rvz[0], cv[1] * rvz[1], cv[2] * rvz[2]]
        n = [n[0] * rvz[0], n[1] * rvz[1], n[2] * rvz[2]]
        let getColor: (simd_float3, Float) -> simd_float3
        if case .color(let c1) = ac[0], case .color(let c2) = ac[1], case .color(let c3) = ac[2] {
            let cc1 = c1 * rvz[0]
            let cc2 = c2 * rvz[1]
            let cc3 = c3 * rvz[2]
            getColor = { w, _ in cc1 * w[0] + cc2 * w[1] + cc3 * w[2] }
        } else if case .texture(let t1) = ac[0], case .texture(let t2) = ac[1], case .texture(let t3) = ac[2] {
            let buffer = Textures.buffer + t1.index << 18
            let tm1 = t1.uv * rvz[0]
            let tm2 = t2.uv * rvz[1]
            let tm3 = t3.uv * rvz[2]
            let dz = simd_float2(simd_dot(rvz, Weight.dx), simd_dot(rvz, Weight.dy))
            let tpp = (tm1 * simd_float2(Weight.dx[0], Weight.dy[0]) +
                       tm2 * simd_float2(Weight.dx[1], Weight.dy[1]) +
                       tm3 * simd_float2(Weight.dx[2], Weight.dy[2]))
            getColor = { w, z in
                let mapping = tm1 * w[0] + tm2 * w[1] + tm3 * w[2]
                let level = z / simd_abs(tpp - mapping * dz)
                return getTextureColor(buffer, mapping, level)
            }
        } else { fatalError() }
        
        for _ in ymin...ymax {
            for _ in xmin...xmax {
                if Weight.w[0] >= 0 && Weight.w[1] >= 0 && Weight.w[2] >= 0 {
                    let z = simd_dot(rvz, Weight.w)
                    if z > Pointers.dBuffer.pointee {
                        Pointers.dBuffer.pointee = z
                        let w = Weight.w / z
                        let point = -simd_fast_normalize(p[0] * w[0] + p[1] * w[1] + p[2] * w[2])
                        let normal = simd_fast_normalize(n[0] * w[0] + n[1] * w[1] + n[2] * w[2])
                        let halfway = simd_fast_normalize(point + normal)
                        let shadedColor = simd_dot(halfway, normal) * getColor(w, z)
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
