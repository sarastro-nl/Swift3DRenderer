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
    let normal: simd_float4
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
    if level.x.isInfinite || level.x.isNaN {
        print("foo \(level)")
    }
    if level.y.isInfinite || level.y.isNaN {
        print("foo \(level)")
    }
    let levelX = nextPowerOfTwo(fmax(fmin(level.x, 256), 1))
    let levelY = nextPowerOfTwo(fmax(fmin(level.y, 256), 1))
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
    Scene.cameraVertices = .allocate(capacity: count.pointee)
    Scene.rasterVertices = .allocate(capacity: count.pointee)

    reader.read(count, maxLength: 16)
    Scene.vertexIndicesCount = count.pointee
    var alignedCount = Scene.vertexIndicesCount + Scene.vertexIndicesCount % 2
    Scene.vertexIndices = .allocate(capacity: alignedCount)
    reader.read(Scene.vertexIndices, maxLength: alignedCount * MemoryLayout<Int>.stride)
    
    reader.read(count, maxLength: 16)
    Scene.attributesCount = count.pointee
    Scene.attributes = .allocate(capacity: Scene.attributesCount)
    reader.read(Scene.attributes, maxLength: Scene.attributesCount * MemoryLayout<VertexAttribute>.stride)
    Scene.normals = .allocate(capacity: Scene.attributesCount)
    
    reader.read(count, maxLength: 16)
    Scene.attributeIndicesCount = count.pointee
    alignedCount = Scene.attributeIndicesCount + Scene.attributeIndicesCount % 2
    Scene.attributeIndices = .allocate(capacity: alignedCount)
    reader.read(Scene.attributeIndices, maxLength: alignedCount * MemoryLayout<Int>.stride)

    reader.read(count, maxLength: 16)
    Textures.buffer = .allocate(capacity: count.pointee)
    reader.read(Textures.buffer, maxLength: count.pointee * MemoryLayout<UInt32>.stride)
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
        let v = simd_mul(State.cameraMatrix, vertex)
        Scene.cameraVertices[i] = v
        if v.z > -Config.near {
            Scene.rasterVertices[i] = simd_float3.zero
        } else {
            Scene.rasterVertices[i] = simd_float3(v.x, -v.y, 0) * Config.factor / -v.z + simd_float3(screenSize / 2, -v.z)
        }
    }
    for (i, attribute) in UnsafeBufferPointer(start: Scene.attributes, count: Scene.attributesCount).enumerated() {
        Scene.normals[i] = simd_mul(State.cameraMatrix, attribute.normal)
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
        
        let (ai1, ai2, ai3) = (Scene.attributeIndices[i], Scene.attributeIndices[i + 1], Scene.attributeIndices[i + 2])
        let (a1, a2, a3) = (Scene.attributes[ai1], Scene.attributes[ai2], Scene.attributes[ai3])
        let rvz = 1 / simd_float3(rv1.z, rv2.z, rv3.z)
        let (n1, n2, n3) = (Scene.normals[ai1] * rvz[0], Scene.normals[ai2] * rvz[1], Scene.normals[ai3] * rvz[2])
        let (p1, p2, p3) = (Scene.cameraVertices[vi1] * rvz[0], Scene.cameraVertices[vi2] * rvz[1], Scene.cameraVertices[vi3] * rvz[2])
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
//            let tmmin = simd_min(simd_min(t1.uv, t2.uv), t3.uv)
//            let tmmax = simd_max(simd_max(t1.uv, t2.uv), t3.uv)
//            let tmdiff = simd_float2(tmmax.x - tmmin.x, tmmax.y - tmmin.y)
//            var tpp2 = tmdiff / simd_abs(tm1 * simd_float2(Weight.dx[0], Weight.dy[0]) +
//                                        tm2 * simd_float2(Weight.dx[1], Weight.dy[1]) +
//                                        tm3 * simd_float2(Weight.dx[2], Weight.dy[2]))
            //            let n = 30
            //            if i == 3 * (n * 2 * (n >> 1) + n - 1) {
            //                print("foo")
            //            }
            if xmin < xmax && ((xmin + 1)..<xmax).contains(480) && ymin < ymax && (ymin..<ymax).contains(293) {
//                print("foo")
            }
//            let dzy = simd_dot(rvz, Weight.dy / 2)
//            let l = tm1.y * Weight.dy[0] / 2 + tm2.y * Weight.dy[1]/2 + tm3.y * Weight.dy[2]/2
            let dz = simd_float2(simd_dot(rvz, Weight.dx), simd_dot(rvz, Weight.dy))
            let tpp = (tm1 * simd_float2(Weight.dx[0], Weight.dy[0]) +
                       tm2 * simd_float2(Weight.dx[1], Weight.dy[1]) +
                       tm3 * simd_float2(Weight.dx[2], Weight.dy[2]))
//            let ll = (tm1.y * Weight.dy[0] + tm2.y * Weight.dy[1] + tm3.y * Weight.dy[2]) / simd_dot(rvz, Weight.dy)
//            let lll = (tm1 * Weight.dy[0] + tm2 * Weight.dy[1] + tm3 * Weight.dy[2]) / simd_float2(simd_dot(rvz, Weight.dx), simd_dot(rvz, Weight.dy))
            getColor = { w, z in
//                let z1 = z - dzy
//                let z2 = z + dzy
//                let y1 = (tm1.y * (Weight.w[0] - Weight.dy[0]/2) + tm2.y * (Weight.w[1] - Weight.dy[1]/2) + tm3.y * (Weight.w[2] - Weight.dy[2]/2)) / z1
//                let y2 = (tm1.y * (Weight.w[0] + Weight.dy[0]/2) + tm2.y * (Weight.w[1] + Weight.dy[1]/2) + tm3.y * (Weight.w[2] + Weight.dy[2]/2)) / z2
//                let diff = y2 - y1
//                let k = tm1.y * Weight.w[0] + tm2.y * Weight.w[1] + tm3.y * Weight.w[2]
                let mapping = tm1 * w[0] + tm2 * w[1] + tm3 * w[2]
//                let my = z1 * z2 / (2 * z * l - 2 * k * dzy)
//                let my2 = 1 / ((k + l) / z2 - (k - l) / z1)
//                let my3 = z1 * z2 / ((k + l) * z1 - (k - l) * z2)
//                let my4 = (z - dzy * dzy / z) / (2 * l - 2 * foo.y * dzy )
//                let my5 = 0.5 * (z / dzy - dzy / z) / (l / dzy - foo.y)
//                let my6 = 0.5 * (z / dzy - dzy / z) / (ll - foo.y)
//                let my7 = 0.5 * (z / dzy - dzy / z) / (lll - foo)
                let my8 = z / simd_abs(tpp - mapping * dz)
//                if abs(my8.y - tpp.y * z) > 5 {
//                    
//                }
//                let zz = simd_dot(rvz, Weight.w - Weight.dy)
//                let ww = (tm1.y * (Weight.w[0] - Weight.dy[0]) + tm2.y * (Weight.w[1] - Weight.dy[1]) + tm3.y * (Weight.w[2] - Weight.dy[2])) / zz
//                let x1 = (tm1.x * (Weight.w[0] - Weight.dx[0]/2) + tm2.x * (Weight.w[1] - Weight.dx[1]/2) + tm3.x * (Weight.w[2] - Weight.dx[2]/2)) / z
//                let x2 = (tm1.x * (Weight.w[0] + Weight.dx[0]/2) + tm2.x * (Weight.w[1] + Weight.dx[1]/2) + tm3.x * (Weight.w[2] + Weight.dx[2]/2)) / z
//                let dx = (tm1.x * Weight.dx[0] + tm2.x * Weight.dx[1] + tm3.x * Weight.dx[2]) / z
//                let dy = (tm1.y * Weight.dy[0] + tm2.y * Weight.dy[1] + tm3.y * Weight.dy[2]) / z
                return getTextureColor(buffer, mapping, my8)
            }
        } else { fatalError() }
        
        for y in ymin...ymax {
            for x in xmin...xmax {
                if Weight.w[0] >= 0 && Weight.w[1] >= 0 && Weight.w[2] >= 0 {
                    let z = simd_dot(rvz, Weight.w)
                    if z > Pointers.dBuffer.pointee {
                        Pointers.dBuffer.pointee = z
                        let w = Weight.w / z
                        let point = -simd_fast_normalize(p1 * w[0] + p2 * w[1] + p3 * w[2])
                        let normal = simd_fast_normalize(n1 * w[0] + n2 * w[1] + n3 * w[2])
                        let halfway = simd_fast_normalize(point + normal)
                        if x == 480 && y == 293 {
//                            print("foo")
                        }
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
