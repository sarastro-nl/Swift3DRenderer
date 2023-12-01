import Foundation
import simd

private struct State {
    static var cameraPosition = simd_float3.zero
    static var cameraAxis = (x: simd_float3(1, 0, 0), y: simd_float3(0, 1, 0), z: simd_float3(0, 0, 1))
    static var cameraMatrix = matrix_identity_float4x4
    static var mouse = simd_float2.zero
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
}

struct Texture {
    //    let wx: Weight
    //    let wy: Weight
    //    let scale: Float
    let index: Int
    let mapping: simd_float2
    
    init(_ index: Int, _ mapping: simd_float2) {
        self.index = index
        self.mapping = mapping
    }
}

struct VertexAttribute {
    let normal: simd_float4
    let colorAttribute: ColorAttribute
    
    init (_ normal: simd_float4, _ colorAttribute: ColorAttribute) {
        self.normal = normal
        self.colorAttribute = colorAttribute
    }
}

enum ColorAttribute {
    case color(simd_float3)
    case texture(Texture)
}

private struct WeightAttribute {
    let point: simd_float3
    let normal: simd_float3
    
    init (_ point: simd_float3, _ normal: simd_float4) {
        self.point = point
        self.normal = simd_float3(normal.x, normal.y, normal.z)
    }
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
    static var initialized = false
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
private func getTextureColor(_ buffer: UnsafePointer<UInt32>, _ mapping: simd_float2) -> simd_float3 {
    let rgb = (buffer + Int(mapping.x) + Int(mapping.y) << 9).pointee
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
        let z: simd_float3 = simd_normalize((State.mouse.x - input.mouse.x) * State.cameraAxis.x +
                                            (State.mouse.y - input.mouse.y) * State.cameraAxis.y +
                                            (100 / Config.rotationSpeed)    * State.cameraAxis.z)
        let q = simd_quatf(from: State.cameraAxis.z, to: z)
        State.cameraAxis.x = simd_normalize(simd_act(q, State.cameraAxis.x))
        State.cameraAxis.y = simd_normalize(simd_act(q, State.cameraAxis.y))
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

func updateAndRender(_ pixelData: inout PixelData, _ input: inout Input) {
    if !Textures.initialized {
        Textures.initialized = true
        Textures.buffer = unsafeBitCast(malloc(texturesSize), to: UnsafeMutablePointer<UInt32>.self)
        guard let reader = InputStream(fileAtPath: Bundle.main.texturePath) else { fatalError() }
        reader.open()
        guard reader.read(Textures.buffer, maxLength: texturesSize) > 0 else { fatalError() }
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

    let size = simd_float2(Float(pixelData.width), Float(pixelData.height))
    let cameraVertices = worldVertices.map {
        simd_make_float3(simd_mul(State.cameraMatrix, $0))
    }
    let rasterVertices = cameraVertices.map {
        simd_float3($0.x, -$0.y, 0) * Config.factor / -$0.z + simd_float3(size / 2, -$0.z)
    }
    let attributes = worldAttributes.map {
        VertexAttribute(simd_mul(State.cameraMatrix, $0.normal), $0.colorAttribute)
    }
    for i in stride(from: 0, to: vertexIndexes.count, by: 3) {
        let (vi1, vi2, vi3) = (vertexIndexes[i], vertexIndexes[i + 1], vertexIndexes[i + 2])
        let (rv1, rv2, rv3) = (rasterVertices[vi1], rasterVertices[vi2], rasterVertices[vi3])
        let rvmin = simd_min(simd_min(rv1, rv2), rv3)
        if rvmin.x >= size[0] || rvmin.y >= size[1] || rvmin.z < Config.near || rvmin.z.isNaN { continue }
        let rvmax = simd_max(simd_max(rv1, rv2), rv3)
        if rvmax.x < 0 || rvmax.y < 0 { continue }
        let area = edgeFunction(rv1, rv2, rv3)
        if area < 10 { continue }
        let oneOverArea = 1 / area
        let (a1, a2, a3) = (attributes[attributeIndexes[i]], attributes[attributeIndexes[i + 1]], attributes[attributeIndexes[i + 2]])
        let rvz = 1 / simd_float3(rv1.z, rv2.z, rv3.z)
        let wa1 = WeightAttribute(cameraVertices[vi1] * rvz[0], a1.normal * rvz[0])
        let wa2 = WeightAttribute(cameraVertices[vi2] * rvz[1], a2.normal * rvz[1])
        let wa3 = WeightAttribute(cameraVertices[vi3] * rvz[2], a3.normal * rvz[2])
        let getColor: (simd_float3) -> simd_float3
        if case .color(let c1) = a1.colorAttribute,
           case .color(let c2) = a2.colorAttribute,
           case .color(let c3) = a3.colorAttribute {
            let cc1 = c1 * rvz[0]
            let cc2 = c2 * rvz[1]
            let cc3 = c3 * rvz[2]
            getColor = { w in cc1 * w[0] + cc2 * w[1] + cc3 * w[2] }
        } else if case .texture(let t1) = a1.colorAttribute,
                  case .texture(let t2) = a2.colorAttribute,
                  case .texture(let t3) = a3.colorAttribute {
            let tt1 = t1.mapping * rvz[0] * 256
            let tt2 = t2.mapping * rvz[1] * 256
            let tt3 = t3.mapping * rvz[2] * 256
            let buffer = Textures.buffer + t1.index << 18
            getColor = { w in getTextureColor(buffer, tt1 * w[0] + tt2 * w[1] + tt3 * w[2]) }
        } else { fatalError() }
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
        for _ in ymin...ymax {
            for _ in xmin...xmax {
                if Weight.w[0] >= 0 && Weight.w[1] >= 0 && Weight.w[2] >= 0 {
                    let z = simd_dot(rvz, Weight.w)
                    if z > Pointers.dBuffer.pointee {
                        Pointers.dBuffer.pointee = z
                        let w = Weight.w / z
                        let point = -simd_normalize(wa1.point * w[0] + wa2.point * w[1] + wa3.point * w[2])
                        let normal = simd_normalize(wa1.normal * w[0] + wa2.normal * w[1] + wa3.normal * w[2])
                        let shadedColor = simd_dot(point, normal) * getColor(w)
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
