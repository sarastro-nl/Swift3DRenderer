import Foundation
import simd
import AppKit

extension NSColor {
    var simd_color: simd_float3 {
        guard let ci = CIColor(color: self) else { return .zero }
        return simd_float3(Float(ci.red * 255), Float(ci.green * 255), Float(ci.blue * 255))
    }
}

extension simd_float3 {
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
        let y = simd_normalize(simd_cross(x, q))
        let z = simd_cross(x, y)
        return (x, y, z)
    }
}

extension FileManager {
    func mergePpms(files: [String], to destination: String) {
        let ppmHeaderSize = 15
        FileManager.default.createFile(atPath: destination, contents: nil)
        guard let writer = FileHandle(forWritingAtPath: destination) else { fatalError() }
        defer { writer.closeFile() }
        for file in files {
            guard let reader = FileHandle(forReadingAtPath: file) else { fatalError() }
            _ = try? reader.read(upToCount: ppmHeaderSize)
            defer { reader.closeFile() }
            guard let dataIn = try? reader.readToEnd() else { fatalError() }
            var data: [UInt32] = []
            for i in stride(from: 0, to: dataIn.count, by: 3) {
                data.append((UInt32(dataIn[i]) << 8 + UInt32(dataIn[i + 1])) << 8 + UInt32(dataIn[i + 2]))
            }
            let dataOut = data.withUnsafeBytes { Data($0) }
            writer.write(dataOut)
        }
    }
}

struct Texture {
    let index: Int
    let mapping: simd_float2

    init(_ index: Int, _ mapping: simd_float2) {
        self.index = index
        self.mapping = mapping
    }
}

enum ColorAttribute {
    case color(simd_float3)
    case texture(Texture)
}

struct VertexAttribute {
    let normal: simd_float3
    let colorAttribute: ColorAttribute
    
    init (_ normal: simd_float3, _ colorAttribute: ColorAttribute) {
        self.normal = normal
        self.colorAttribute = colorAttribute
    }
}

var vertices: [simd_float3] = []
var vertexIndexes: [Int] = []
var attributes: [VertexAttribute] = []
var attributeIndexes: [Int] = []

let orange = NSColor.orange.simd_color
let red = NSColor.red.simd_color
let blue = NSColor.blue.simd_color

func normal(_ v: [simd_float3], _ a: Int, _ b: Int, _ c: Int) -> simd_float3 {
    (simd_cross(v[c] - v[a], v[b] - v[a]))
}

func addTriangle() {
    var v: [simd_float3] = [
        simd_float3(-sqrt(3)/2, -0.5, 0),
        simd_float3(0, 1, 0),
        simd_float3(sqrt(3)/2, -0.5, 0),
    ]
    //    let a: Float = 0.003
    //    var v: [simd_float3] = [
    //        simd_float3(-a, -0.5, -sqrt(3)/2),
    //        simd_float3(a, -0.5, sqrt(3)/2),
    //        simd_float3(0, 1, 0),
    //    ]
    //    let r = Float.random(in: 1...10)
    //    let p = simd_float3.randomPoint
    let r: Float = 1.0
    let p = simd_float3(0, 0, -10)
    v = v.map { r * $0 + p }
    vertices.append(contentsOf: v)
    vertexIndexes.append(contentsOf: [
        0, 1, 2,
    ])
    attributes.append(contentsOf: [
        //        VertexAttribute(normal(v, 0, 1, 2), .color(red)),
        //        VertexAttribute(normal(v, 0, 1, 2), .color(orange)),
        //        VertexAttribute(normal(v, 0, 1, 2), .color(blue)),
        VertexAttribute(normal(v, 0, 1, 2), .texture(Texture(0, simd_float2(0, sqrt(3)/2)))),
        VertexAttribute(normal(v, 0, 1, 2), .texture(Texture(0, simd_float2(0.5, 0)))),
        VertexAttribute(normal(v, 0, 1, 2), .texture(Texture(0, simd_float2(1, sqrt(3)/2)))),
    ])
    let j = attributeIndexes.count
    attributeIndexes.append(contentsOf: (j..<(j + 3)))
}

func addRegularFloor() {
    let a = 3
    for z in 0...a {
        for x in 0...a {
            var extra: Float = 0
            if z % 2 == 1 {
                extra = 0.5
            }
            vertices.append(simd_float3(Float(x) - Float(a + 1) / 2 + extra, -0.5, -Float(z) * sqrt(3) / 2 - 2))
        }
    }
    let scale: Float = 0.8
    for z in 0..<a {
        let a1 = z * (a + 1)
        let a2 = (z + 1) * (a + 1)
        for x in 0..<a {
            let xStart = fmodf(Float(x) * scale, 1.0)
            let yStart = fmodf(Float(a - z - 1) * scale, 1.0)
            if z % 2 == 0 {
                vertexIndexes.append(contentsOf: [a1 + x, a2 + x, a1 + 1 + x, a1 + 1 + x, a2 + x, a2 + 1 + x,])
                if true {
                    let t1 = simd_float2(xStart + 0 * scale, yStart + 1 * scale)
                    let t2 = simd_float2(xStart + 0.5 * scale, yStart + 0 * scale)
                    let t3 = simd_float2(xStart + 1 * scale, yStart + 1 * scale)
                    attributes.append(contentsOf: [
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t1))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t2))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t3))),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(red)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(red)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(red)),
                    ])
                }
                if true {
                    let t1 = simd_float2(xStart + 1 * scale, yStart + 1 * scale)
                    let t2 = simd_float2(xStart + 0.5 * scale, yStart + 0 * scale)
                    let t3 = simd_float2(xStart + 1.5 * scale, yStart + 0 * scale)
//                    let t1 = simd_float2(fmodf((Float(x) + 1) * scale, 1.0), fmodf((Float(a - z - 1) + 1) * scale, 1.0))
//                    let t2 = simd_float2(fmodf((Float(x) + 0.5) * scale, 1.0), fmodf((Float(a - z - 1) + 0) * scale, 1.0))
//                    let t3 = simd_float2(fmodf((Float(x) + 1.5) * scale, 1.0), fmodf((Float(a - z - 1) + 0) * scale, 1.0))
                    attributes.append(contentsOf: [
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t1))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t2))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t3))),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(orange)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(orange)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(orange)),
                    ])
                }
            } else {
                vertexIndexes.append(contentsOf: [a1 + x, a2 + x, a2 + 1 + x, a2 + 1 + x, a1 + 1 + x, a1 + x,])
                if true {
                    let t1 = simd_float2(xStart + 0.5 * scale, yStart + 1 * scale)
                    let t2 = simd_float2(xStart + 0 * scale, yStart + 0 * scale)
                    let t3 = simd_float2(xStart + 1 * scale, yStart + 0 * scale)
//                    let t1 = simd_float2(fmodf((Float(x) + 0.5) * scale, 1.0), fmodf((Float(a - z - 1) + 1) * scale, 1.0))
//                    let t2 = simd_float2(fmodf((Float(x) + 0) * scale, 1.0), fmodf((Float(a - z - 1) + 0) * scale, 1.0))
//                    let t3 = simd_float2(fmodf((Float(x) + 1) * scale, 1.0), fmodf((Float(a - z - 1) + 0) * scale, 1.0))
                    attributes.append(contentsOf: [
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t1))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t2))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t3))),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(orange)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(orange)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(orange)),
                    ])
                }
                if true {
                    let t1 = simd_float2(xStart + 1 * scale, yStart + 0 * scale)
                    let t2 = simd_float2(xStart + 1.5 * scale, yStart + 1 * scale)
                    let t3 = simd_float2(xStart + 0.5 * scale, yStart + 1 * scale)
//                    let t1 = simd_float2(fmodf((Float(x) + 1) * scale, 1.0), fmodf((Float(a - z - 1) + 0) * scale, 1.0))
//                    let t2 = simd_float2(fmodf((Float(x) + 1.5) * scale, 1.0), fmodf((Float(a - z - 1) + 1) * scale, 1.0))
//                    let t3 = simd_float2(fmodf((Float(x) + 0.5) * scale, 1.0), fmodf((Float(a - z - 1) + 1) * scale, 1.0))
                    attributes.append(contentsOf: [
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t1))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t2))),
                        VertexAttribute(simd_float3(0, 1, 0), .texture(Texture(0, t3))),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(blue)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(blue)),
//                        VertexAttribute(simd_float3(0, 1, 0), .color(blue)),
                    ])
                }
            }
            let j = attributeIndexes.count
            attributeIndexes.append(contentsOf: j..<(j+6))
        }
    }
}

func addTetrahedron() {
    let (x, y, z) = simd_float3.randomUnitAxis
    let k1: Float = sqrt(8/9)
    let k2: Float = sqrt(2/9)
    let k3: Float = sqrt(2/3)
    var v: [simd_float3] = [
        z,
        k1 * x          - z / 3,
        -k2 * x + k3 * y - z / 3,
        -k2 * x - k3 * y - z / 3,
    ]
    //    let r = Float.random(in: 1...10)
    //    let p = simd_float3.randomPoint
    let r: Float = 2.0
    let p = simd_float3(0, 0, -50)
    v = v.map { r * $0 + p }
    let i = vertices.count
    vertices.append(contentsOf: v)
    vertexIndexes.append(contentsOf: [
        i,   i+2, i+1,
        i,   i+3, i+2,
        i,   i+1, i+3,
        i+1, i+2, i+3,
    ])
    let j = attributes.count
    attributes.append(contentsOf: [
        VertexAttribute(normal(v, 0, 2, 1), .color(orange)),
        VertexAttribute(normal(v, 0, 2, 1), .color(orange)),
        VertexAttribute(normal(v, 0, 2, 1), .color(orange)),
        VertexAttribute(normal(v, 0, 3, 2), .color(red)),
        VertexAttribute(normal(v, 0, 3, 2), .color(orange)),
        VertexAttribute(normal(v, 0, 3, 2), .color(orange)),
        VertexAttribute(normal(v, 0, 1, 3), .color(orange)),
        VertexAttribute(normal(v, 0, 1, 3), .color(orange)),
        VertexAttribute(normal(v, 0, 1, 3), .color(blue)),
        VertexAttribute(normal(v, 1, 2, 3), .color(orange)),
        VertexAttribute(normal(v, 1, 2, 3), .color(orange)),
        VertexAttribute(normal(v, 1, 2, 3), .color(orange)),
    ])
    attributeIndexes.append(contentsOf: (j..<(j + 12)))
}

func addIcosahedron() {
    let (x, y, z) = simd_float3.randomUnitAxis
    let phi: Float = (sqrt(5) + 1) / 2
    let l: Float = 1 / sqrt(phi + 2)
    let k: Float = phi * l
    var v: [simd_float3] = [
        k * x + l * y,
        k * x - l * y,
        -k * x + l * y,
        -k * x - l * y,
        l * x         + k * z,
        -l * x         + k * z,
        l * x         - k * z,
        -l * x         - k * z,
        k * y + l * z,
        k * y - l * z,
        -k * y + l * z,
        -k * y - l * z,
    ]
    //    let r = Float.random(in: 1...10)
    //    let p = simd_float3.randomPoint
    let r: Float = 2.0
    let p = simd_float3(0, 0, -50)
    v = v.map { r * $0 + p }
    
    let i = vertices.count
    vertices.append(contentsOf: v)
    vertexIndexes.append(contentsOf: [
        i,    i+1,  i+4,
        i+4,  i+8,  i,
        i,    i+8,  i+9,
        i+9,  i+6,  i,
        i,    i+6,  i+1,
        i+1,  i+10, i+4,
        i+4,  i+10, i+5,
        i+5,  i+8,  i+4,
        i+5,  i+2,  i+8,
        i+8,  i+2,  i+9,
        i+9,  i+2,  i+7,
        i+7,  i+6,  i+9,
        i+7,  i+11, i+6,
        i+6,  i+11, i+1,
        i+1,  i+11, i+10,
        i+3,  i+5,  i+10,
        i+10, i+11, i+3,
        i+3,  i+11, i+7,
        i+7,  i+2,  i+3,
        i+3,  i+2,  i+5,
    ])
    let j = attributes.count
    attributes.append(contentsOf: [
        VertexAttribute(normal(v, 0, 1, 4), .color(orange)),
        VertexAttribute(normal(v, 0, 1, 4), .color(orange)),
        VertexAttribute(normal(v, 0, 1, 4), .color(orange)),
        VertexAttribute(normal(v, 4, 8, 0), .color(orange)),
        VertexAttribute(normal(v, 4, 8, 0), .color(orange)),
        VertexAttribute(normal(v, 4, 8, 0), .color(orange)),
        VertexAttribute(normal(v, 0, 8, 9), .color(orange)),
        VertexAttribute(normal(v, 0, 8, 9), .color(orange)),
        VertexAttribute(normal(v, 0, 8, 9), .color(orange)),
        VertexAttribute(normal(v, 9, 6, 0), .color(red)),
        VertexAttribute(normal(v, 9, 6, 0), .color(orange)),
        VertexAttribute(normal(v, 9, 6, 0), .color(orange)),
        VertexAttribute(normal(v, 0, 6, 1), .color(orange)),
        VertexAttribute(normal(v, 0, 6, 1), .color(orange)),
        VertexAttribute(normal(v, 0, 6, 1), .color(orange)),
        VertexAttribute(normal(v, 1, 10, 4), .color(orange)),
        VertexAttribute(normal(v, 1, 10, 4), .color(orange)),
        VertexAttribute(normal(v, 1, 10, 4), .color(orange)),
        VertexAttribute(normal(v, 4, 10, 5), .color(orange)),
        VertexAttribute(normal(v, 4, 10, 5), .color(orange)),
        VertexAttribute(normal(v, 4, 10, 5), .color(orange)),
        VertexAttribute(normal(v, 5, 8, 4), .color(orange)),
        VertexAttribute(normal(v, 5, 8, 4), .color(orange)),
        VertexAttribute(normal(v, 5, 8, 4), .color(orange)),
        VertexAttribute(normal(v, 5, 2, 8), .color(blue)),
        VertexAttribute(normal(v, 5, 2, 8), .color(orange)),
        VertexAttribute(normal(v, 5, 2, 8), .color(red)),
        VertexAttribute(normal(v, 8, 2, 9), .color(orange)),
        VertexAttribute(normal(v, 8, 2, 9), .color(orange)),
        VertexAttribute(normal(v, 8, 2, 9), .color(orange)),
        VertexAttribute(normal(v, 9, 2, 7), .color(orange)),
        VertexAttribute(normal(v, 9, 2, 7), .color(orange)),
        VertexAttribute(normal(v, 9, 2, 7), .color(orange)),
        VertexAttribute(normal(v, 7, 6, 9), .color(orange)),
        VertexAttribute(normal(v, 7, 6, 9), .color(orange)),
        VertexAttribute(normal(v, 7, 6, 9), .color(orange)),
        VertexAttribute(normal(v, 7, 11, 6), .color(orange)),
        VertexAttribute(normal(v, 7, 11, 6), .color(orange)),
        VertexAttribute(normal(v, 7, 11, 6), .color(orange)),
        VertexAttribute(normal(v, 6, 11, 1), .color(orange)),
        VertexAttribute(normal(v, 6, 11, 1), .color(orange)),
        VertexAttribute(normal(v, 6, 11, 1), .color(orange)),
        VertexAttribute(normal(v, 1, 11, 10), .color(orange)),
        VertexAttribute(normal(v, 1, 11, 10), .color(orange)),
        VertexAttribute(normal(v, 1, 11, 10), .color(orange)),
        VertexAttribute(normal(v, 3, 5, 10), .color(red)),
        VertexAttribute(normal(v, 3, 5, 10), .color(orange)),
        VertexAttribute(normal(v, 3, 5, 10), .color(orange)),
        VertexAttribute(normal(v, 10, 11, 3), .color(orange)),
        VertexAttribute(normal(v, 10, 11, 3), .color(orange)),
        VertexAttribute(normal(v, 10, 11, 3), .color(orange)),
        VertexAttribute(normal(v, 3, 11, 7), .color(orange)),
        VertexAttribute(normal(v, 3, 11, 7), .color(orange)),
        VertexAttribute(normal(v, 3, 11, 7), .color(orange)),
        VertexAttribute(normal(v, 7, 2, 3), .color(orange)),
        VertexAttribute(normal(v, 7, 2, 3), .color(orange)),
        VertexAttribute(normal(v, 7, 2, 3), .color(orange)),
        VertexAttribute(normal(v, 3, 2, 5), .color(orange)),
        VertexAttribute(normal(v, 3, 2, 5), .color(orange)),
        VertexAttribute(normal(v, 3, 2, 5), .color(orange)),
    ])
    attributeIndexes.append(contentsOf: (j..<(j + 60)))
}

//addRegularFloor()
for _ in (0..<1) { addTriangle() }
//for _ in (0..<2) { addTetrahedron() }
//for _ in (0..<2) { addIcosahedron() }


let directory = String(#file.prefix(upTo: #file.lastIndex(of: "/")!))
let swiftPath = directory + "/data.swift"
let hppPath = directory + "/data.hpp"
if !FileManager.default.fileExists(atPath: swiftPath) {
    FileManager.default.createFile(atPath: swiftPath, contents: nil)
}
if !FileManager.default.fileExists(atPath: hppPath) {
    FileManager.default.createFile(atPath: hppPath, contents: nil)
}

let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory + "/ppms").sorted()
FileManager.default.mergePpms(files: directoryContents.map { directory + "/ppms/" + $0 }, to: directory + "/textures.bin")

var s = """
// this file is generated
import simd
let texturesSize = \(directoryContents.count * 512 * 512 * 4)
let worldVertices: [simd_float4] = [\n
"""
for v in vertices {
    s += "simd_float4(\(v.x), \(v.y), \(v.z), 1),\n"
}
s += """
]
let vertexIndexes = [\n
"""
for i in stride(from: 0, to: vertexIndexes.count, by: 3) {
    s += "\(vertexIndexes[i]), \(vertexIndexes[i+1]), \(vertexIndexes[i+2]),\n"
}
s += """
]
let worldAttributes: [VertexAttribute] = [\n
"""
for a in attributes {
    s += "VertexAttribute(simd_float4(\(a.normal.x), \(a.normal.y), \(a.normal.z), 0), "
    switch a.colorAttribute {
        case .color(let c):
            s += ".color(simd_float3(\(c[0]), \(c[1]), \(c[2])))),\n"
        case .texture(let t):
            s += ".texture(Texture(\(t.index), simd_float2(\(t.mapping.x), \(t.mapping.y))))),\n"
    }
}
s += """
]
let attributeIndexes = [\n
"""
for i in stride(from: 0, to: attributeIndexes.count, by: 3) {
    s += "\(attributeIndexes[i]), \(attributeIndexes[i+1]), \(attributeIndexes[i+2]),\n"
}
s += """
]
"""

try s.write(toFile: swiftPath, atomically: true, encoding: .utf8)

s = """
// this file is generated
#include <simd/simd.h>
#include "../render-cpp/render.hpp"
const int32_t world_vertices_count = \(vertices.count);
const int32_t world_attributes_count = \(attributes.count);
const int32_t world_triangles_count = \(vertexIndexes.count/3);
const int32_t textures_size = \(directoryContents.count * 512 * 512 * 4);
const simd_float4 world_vertices[\(vertices.count)] = {\n
"""
for v in vertices {
    s += "(simd_float4){\(v.x), \(v.y), \(v.z), 1},\n"
}
s += """
};
const int32_t vertex_indexes[\(vertexIndexes.count)] = {\n
"""
for i in stride(from: 0, to: vertexIndexes.count, by: 3) {
    s += "\(vertexIndexes[i]), \(vertexIndexes[i+1]), \(vertexIndexes[i+2]),\n"
}
s += """
};
const vertex_attribute_t world_attributes[\(attributes.count)] = {\n
"""
for a in attributes {
    s += "{ .normal = {\(a.normal.x), \(a.normal.y), \(a.normal.z), 0}, "
    switch a.colorAttribute {
        case .color(let c):
            s += ".disc = color, .color_attribute = {{\(c[0]), \(c[1]), \(c[2])}}},\n"
        case .texture(let t):
            s += ".disc = texture, .color_attribute = { .texture = {\(t.index), {\(t.mapping.x), \(t.mapping.y)}}}},\n"
    }
}
s += """
};
const int32_t attribute_indexes[\(attributeIndexes.count)] = {\n
"""
for i in stride(from: 0, to: attributeIndexes.count, by: 3) {
    s += "\(attributeIndexes[i]), \(attributeIndexes[i+1]), \(attributeIndexes[i+2]),\n"
}
s += """
};
"""

try s.write(toFile: hppPath, atomically: true, encoding: .utf8)
