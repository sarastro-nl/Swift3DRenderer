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
    static let backgroundColor = RGB(30, 30, 30)
}

private struct Attribute {
    var point: simd_float3
    let normal: simd_float3
    let color: simd_float3
}

private func RGB(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
    guard r < 256, g < 256, b < 256 else { fatalError() }
    return (256 * UInt32(r) + UInt32(g)) * 256 + UInt32(b)
}

private func edgeFunction(_ v1: inout simd_float3, _ v2: inout simd_float3, _ v3: inout simd_float3) -> Float {
    (v3.x - v1.x) * (v1.y - v2.y) + (v3.y - v1.y) * (v2.x - v1.x)
}

private func updateCamera(_ input: inout Input) {
    var changed = false
    if input.left > 0 || input.right > 0 || input.up > 0 || input.down > 0 {
        changed = true
        State.cameraPosition += Config.speed * ((input.right - input.left) * State.cameraAxis.x + (input.down - input.up) * State.cameraAxis.z)
    }
    if input.mouse != State.mouse {
        changed = true
        let z = (State.mouse.x - input.mouse.x) * State.cameraAxis.x + (State.mouse.y - input.mouse.y) * State.cameraAxis.y + (100 / Config.rotationSpeed) * State.cameraAxis.z
        let nz = normalize(z)
        let q = simd_quatf(from: State.cameraAxis.z, to: nz)
        State.cameraAxis.x = normalize(simd_act(q, State.cameraAxis.x))
        State.cameraAxis.y = normalize(simd_act(q, State.cameraAxis.y))
        State.cameraAxis.z = nz
        State.mouse = input.mouse
    }
    if changed {
        State.cameraMatrix = simd_inverse(simd_float4x4(simd_float4(State.cameraAxis.x, 0),
                                                        simd_float4(State.cameraAxis.y, 0),
                                                        simd_float4(State.cameraAxis.z, 0),
                                                        simd_float4(State.cameraPosition, 1)))
    }
}

func updateAndRender(_ pixelData: inout PixelData, _ input: inout Input) {
    updateCamera(&input)

    let depthBufferSize = Int(pixelData.width * pixelData.height) * MemoryLayout<Float>.size
    if DepthBuffer.bufferSize != depthBufferSize {
        DepthBuffer.bufferSize = depthBufferSize
        DepthBuffer.buffer = unsafeBitCast(realloc(DepthBuffer.buffer, depthBufferSize), to: UnsafeMutablePointer<Float>.self)
        Config.factor = Config.near * Float(pixelData.height) / (2 * Config.scale)
    }
    var infinity = Float.infinity
    memset_pattern4(DepthBuffer.buffer, &infinity, depthBufferSize)
    var backgroundColor = Config.backgroundColor
    memset_pattern4(pixelData.pixelBuffer, &backgroundColor, Int(pixelData.bufferSize))

    let width = Float(pixelData.width)
    let height = Float(pixelData.height)
    let cameraVertices = worldVertices.map {
        simd_make_float3(simd_mul(State.cameraMatrix, $0))
    }
    let rasterVertices = cameraVertices.map {
        simd_float3($0.x, -$0.y, 0) * Config.factor / -$0.z + simd_float3(width / 2, height / 2, -$0.z)
    }
    let attributes = worldAttributes.map {
        Attribute(point: .zero, normal: simd_make_float3(simd_mul(State.cameraMatrix, $0.normal)), color: $0.color)
    }
    for i in stride(from: 0, to: worldVertexIndexes.count, by: 3) {
        let (vi1, vi2, vi3) = (worldVertexIndexes[i], worldVertexIndexes[i + 1], worldVertexIndexes[i + 2])
        var (rv1, rv2, rv3) = (rasterVertices[vi1], rasterVertices[vi2], rasterVertices[vi3])
        let rvmin = simd_min(simd_min(rv1, rv2), rv3)
        let rvmax = simd_max(simd_max(rv1, rv2), rv3)
        if rvmin.x >= width || rvmin.y >= height || rvmax.x < 0 || rvmax.y < 0 || rvmin.z < Config.near { continue }
        
        let area = edgeFunction(&rv1, &rv2, &rv3)
        let (ai1, ai2, ai3) = (worldAttributeIndexes[i], worldAttributeIndexes[i + 1], worldAttributeIndexes[i + 2])
        let (a1, a2, a3) = (attributes[ai1], attributes[ai2], attributes[ai3])
        let rvz = 1 / simd_float3(rv1.z, rv2.z, rv3.z)
        let (preMul1, preMul2, preMul3) = (Attribute(point: cameraVertices[vi1] * rvz[0], normal: a1.normal * rvz[0], color: a1.color * rvz[0]),
                                           Attribute(point: cameraVertices[vi2] * rvz[1], normal: a2.normal * rvz[1], color: a2.color * rvz[1]),
                                           Attribute(point: cameraVertices[vi3] * rvz[2], normal: a3.normal * rvz[2], color: a3.color * rvz[2]))
        let xmin = max(0, Int(rvmin.x))
        let xmax = min(Int(pixelData.width) - 1, Int(rvmax.x))
        let ymin = max(0, Int(rvmin.y))
        let ymax = min(Int(pixelData.height) - 1, Int(rvmax.y))
        for y in (ymin...ymax) {
            let ypart = y * Int(pixelData.width)
            for x in (xmin...xmax) {
                var p = simd_float3(Float(x) + 0.5, Float(y) + 0.5, 0)
                var w = simd_float3(edgeFunction(&rv2, &rv3, &p), edgeFunction(&rv3, &rv1, &p), edgeFunction(&rv1, &rv2, &p))
                if w >= .zero {
                    w /= area
                    let xpart = x + ypart
                    let z = 1 / dot(rvz, w)
                    if z < DepthBuffer.buffer[xpart] {
                        DepthBuffer.buffer[xpart] = z
                        let point = z * (preMul1.point * w[0] + preMul2.point * w[1] + preMul3.point * w[2])
                        let normal = z * (preMul1.normal * w[0] + preMul2.normal * w[1] + preMul3.normal * w[2])
                        let color = z * (preMul1.color * w[0] + preMul2.color * w[1] + preMul3.color * w[2])
                        let p = -normalize(point)
                        let n = normalize(normal)
                        let dot = dot(p, n)
                        pixelData.pixelBuffer[xpart] = RGB(dot * color[0], dot * color[1], dot * color[2])
                    }
                }
            }
        }
    }
}
