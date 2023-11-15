import simd

extension simd_float3 {
    static func >= (lhs: simd_float3, rhs: simd_float3) -> Bool { lhs.x >= rhs.x && lhs.y >= rhs.y && lhs.z >= rhs.z }

    static var randomPoint: simd_float3 { simd_float3(Float.random(in: -100...100), Float.random(in: -100...100), Float.random(in: -100...100)) }

    static var randomUnitSpherePoint: simd_float3 {
        let cz = Float.random(in: -1...1)
        let angle = Float.random(in: 0..<2*Float.pi)
        let cx = cos(angle) * sqrt(1 - cz * cz)
        let cy = sin(angle) * sqrt(1 - cz * cz)
        return simd_float3(cx, cy, cz)
    }
    
    static var randomUnitAxis: (simd_float3, simd_float3, simd_float3) {
        let x = simd_float3.randomUnitSpherePoint
        var q: simd_float3
        repeat {
            q = simd_float3.randomUnitSpherePoint
        } while q == x || q == -x
        let y = normalize(cross(x, q))
        let z = cross(x, y)
        return (x, y, z)
    }
}

extension simd_float3x3 {
    static func rotationMatrix(_ a: simd_float3, _ b: simd_float3) -> Self {
        let n = normalize(cross(a, b))
        let c = dot(a, b)
        let s = sqrt(max(0, 1 - c * c))
        let ci = 1 - c
        return simd_float3x3(simd_float3(c + n.x * n.x * ci, n.y * n.x * ci + n.z * s, n.z * n.x * ci - n.y * s),
                             simd_float3(n.x * n.y * ci - n.z * s, c + n.y * n.y * ci, n.z * n.y * ci + n.x * s),
                             simd_float3(n.x * n.z * ci + n.y * s, n.y * n.z * ci - n.x * s, c + n.z * n.z * ci))
    }
}

extension simd_float4x4: CustomStringConvertible {
    public var description: String {
        let m = self
        var s = ""
        s += String(format: "%.5f  %.5f  %.5f  %.5f\n", m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        s += String(format: "%.5f  %.5f  %.5f  %.5f\n", m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        s += String(format: "%.5f  %.5f  %.5f  %.5f\n", m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        s += String(format: "%.5f  %.5f  %.5f  %.5f\n", m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        return s
    }
}
