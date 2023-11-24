import Foundation
import simd
import AppKit

struct VertexAttribute {
    let n: simd_float3
    let c: simd_float3
}

var vertices: [simd_float3] = []
var vertexIndexes: [Int] = []
var attributes: [VertexAttribute] = []
var attributeIndexes: [Int] = []

extension NSColor {
    var simd_color: simd_float3 {
        guard let ci = CIColor(color: self) else { return .zero }
        return simd_float3(Float(ci.red * 255), Float(ci.green * 255), Float(ci.blue * 255))
    }
}

let orange = NSColor.orange.simd_color
let red = NSColor.red.simd_color
let blue = NSColor.blue.simd_color

func normal(_ v: [simd_float3], _ a: Int, _ b: Int, _ c: Int) -> simd_float3 { normalize(cross(v[c] - v[a], v[b] - v[a])) }

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
    let p = simd_float3(0, 0, -100)
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
        VertexAttribute(n: normal(v, 0, 2, 1), c: orange),
        VertexAttribute(n: normal(v, 0, 2, 1), c: orange),
        VertexAttribute(n: normal(v, 0, 2, 1), c: orange),
        VertexAttribute(n: normal(v, 0, 3, 2), c: red),
        VertexAttribute(n: normal(v, 0, 3, 2), c: orange),
        VertexAttribute(n: normal(v, 0, 3, 2), c: orange),
        VertexAttribute(n: normal(v, 0, 1, 3), c: orange),
        VertexAttribute(n: normal(v, 0, 1, 3), c: orange),
        VertexAttribute(n: normal(v, 0, 1, 3), c: blue),
        VertexAttribute(n: normal(v, 1, 2, 3), c: orange),
        VertexAttribute(n: normal(v, 1, 2, 3), c: orange),
        VertexAttribute(n: normal(v, 1, 2, 3), c: orange),
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
        VertexAttribute(n: normal(v, 0, 1, 4), c: orange),
        VertexAttribute(n: normal(v, 0, 1, 4), c: orange),
        VertexAttribute(n: normal(v, 0, 1, 4), c: orange),
        VertexAttribute(n: normal(v, 4, 8, 0), c: orange),
        VertexAttribute(n: normal(v, 4, 8, 0), c: orange),
        VertexAttribute(n: normal(v, 4, 8, 0), c: orange),
        VertexAttribute(n: normal(v, 0, 8, 9), c: orange),
        VertexAttribute(n: normal(v, 0, 8, 9), c: orange),
        VertexAttribute(n: normal(v, 0, 8, 9), c: orange),
        VertexAttribute(n: normal(v, 9, 6, 0), c: red),
        VertexAttribute(n: normal(v, 9, 6, 0), c: orange),
        VertexAttribute(n: normal(v, 9, 6, 0), c: orange),
        VertexAttribute(n: normal(v, 0, 6, 1), c: orange),
        VertexAttribute(n: normal(v, 0, 6, 1), c: orange),
        VertexAttribute(n: normal(v, 0, 6, 1), c: orange),
        VertexAttribute(n: normal(v, 1, 10, 4), c: orange),
        VertexAttribute(n: normal(v, 1, 10, 4), c: orange),
        VertexAttribute(n: normal(v, 1, 10, 4), c: orange),
        VertexAttribute(n: normal(v, 4, 10, 5), c: orange),
        VertexAttribute(n: normal(v, 4, 10, 5), c: orange),
        VertexAttribute(n: normal(v, 4, 10, 5), c: orange),
        VertexAttribute(n: normal(v, 5, 8, 4), c: orange),
        VertexAttribute(n: normal(v, 5, 8, 4), c: orange),
        VertexAttribute(n: normal(v, 5, 8, 4), c: orange),
        VertexAttribute(n: normal(v, 5, 2, 8), c: blue),
        VertexAttribute(n: normal(v, 5, 2, 8), c: orange),
        VertexAttribute(n: normal(v, 5, 2, 8), c: red),
        VertexAttribute(n: normal(v, 8, 2, 9), c: orange),
        VertexAttribute(n: normal(v, 8, 2, 9), c: orange),
        VertexAttribute(n: normal(v, 8, 2, 9), c: orange),
        VertexAttribute(n: normal(v, 9, 2, 7), c: orange),
        VertexAttribute(n: normal(v, 9, 2, 7), c: orange),
        VertexAttribute(n: normal(v, 9, 2, 7), c: orange),
        VertexAttribute(n: normal(v, 7, 6, 9), c: orange),
        VertexAttribute(n: normal(v, 7, 6, 9), c: orange),
        VertexAttribute(n: normal(v, 7, 6, 9), c: orange),
        VertexAttribute(n: normal(v, 7, 11, 6), c: orange),
        VertexAttribute(n: normal(v, 7, 11, 6), c: orange),
        VertexAttribute(n: normal(v, 7, 11, 6), c: orange),
        VertexAttribute(n: normal(v, 6, 11, 1), c: orange),
        VertexAttribute(n: normal(v, 6, 11, 1), c: orange),
        VertexAttribute(n: normal(v, 6, 11, 1), c: orange),
        VertexAttribute(n: normal(v, 1, 11, 10), c: orange),
        VertexAttribute(n: normal(v, 1, 11, 10), c: orange),
        VertexAttribute(n: normal(v, 1, 11, 10), c: orange),
        VertexAttribute(n: normal(v, 3, 5, 10), c: red),
        VertexAttribute(n: normal(v, 3, 5, 10), c: orange),
        VertexAttribute(n: normal(v, 3, 5, 10), c: orange),
        VertexAttribute(n: normal(v, 10, 11, 3), c: orange),
        VertexAttribute(n: normal(v, 10, 11, 3), c: orange),
        VertexAttribute(n: normal(v, 10, 11, 3), c: orange),
        VertexAttribute(n: normal(v, 3, 11, 7), c: orange),
        VertexAttribute(n: normal(v, 3, 11, 7), c: orange),
        VertexAttribute(n: normal(v, 3, 11, 7), c: orange),
        VertexAttribute(n: normal(v, 7, 2, 3), c: orange),
        VertexAttribute(n: normal(v, 7, 2, 3), c: orange),
        VertexAttribute(n: normal(v, 7, 2, 3), c: orange),
        VertexAttribute(n: normal(v, 3, 2, 5), c: orange),
        VertexAttribute(n: normal(v, 3, 2, 5), c: orange),
        VertexAttribute(n: normal(v, 3, 2, 5), c: orange),
    ])
    attributeIndexes.append(contentsOf: (j..<(j + 60)))
}

for _ in (0..<1) { addTetrahedron() }
//for _ in (0..<1) { addIcosahedron() }

let directory = String(#file.prefix(upTo: #file.lastIndex(of: "/")!))
let swiftPath = directory + "/data.swift"
let hppPath = directory + "/data.hpp"
if !FileManager.default.fileExists(atPath: swiftPath) {
    FileManager.default.createFile(atPath: swiftPath, contents: nil)
}
if !FileManager.default.fileExists(atPath: hppPath) {
    FileManager.default.createFile(atPath: hppPath, contents: nil)
}

var s = """
import simd
struct VertexAttribute {
let normal: simd_float4
let color: simd_float3
}
let worldVertices: [simd_float4] = [

"""
for v in vertices {
    s += "simd_float4(\(v.x), \(v.y), \(v.z), 1),\n"
}
s += """
]
let worldVertexIndexes = [

"""
for i in stride(from: 0, to: vertexIndexes.count, by: 3) {
    s += "\(vertexIndexes[i]), \(vertexIndexes[i+1]), \(vertexIndexes[i+2]),\n"
}
s += """
]
let worldAttributes: [VertexAttribute] = [

"""
for a in attributes {
    s += "VertexAttribute(normal: simd_float4(\(a.n.x), \(a.n.y), \(a.n.z), 0), color: simd_float3(\(a.c.x), \(a.c.y), \(a.c.z))),\n"
}
s += """
]
let worldAttributeIndexes = [

"""
for i in stride(from: 0, to: attributeIndexes.count, by: 3) {
    s += "\(attributeIndexes[i]), \(attributeIndexes[i+1]), \(attributeIndexes[i+2]),\n"
}
s += """
]
"""

try s.write(toFile: swiftPath, atomically: true, encoding: .utf8)

s = """
#include <simd/simd.h>
typedef struct {
simd_float4 normal;
simd_float3 color;
} vertex_attribute_t;
const int32_t world_vertices_count = \(vertices.count);
const int32_t world_attributes_count = \(attributes.count);
const int32_t world_triangles_count = \(vertexIndexes.count/3);
simd_float4 world_vertices[\(vertices.count)] = {

"""
for v in vertices {
    s += "(simd_float4){\(v.x), \(v.y), \(v.z), 1},\n"
}
s += """
};
int32_t world_vertex_indexes[\(vertexIndexes.count)] = {

"""
for i in stride(from: 0, to: vertexIndexes.count, by: 3) {
    s += "\(vertexIndexes[i]), \(vertexIndexes[i+1]), \(vertexIndexes[i+2]),\n"
}
s += """
};
vertex_attribute_t world_attributes[\(attributes.count)] = {

"""
for a in attributes {
    s += "(vertex_attribute_t){{\(a.n.x), \(a.n.y), \(a.n.z), 0}, {\(a.c.x), \(a.c.y), \(a.c.z)}},\n"
}
s += """
};
int32_t world_attribute_indexes[\(attributeIndexes.count)] = {

"""
for i in stride(from: 0, to: attributeIndexes.count, by: 3) {
    s += "\(attributeIndexes[i]), \(attributeIndexes[i+1]), \(attributeIndexes[i+2]),\n"
}
s += """
};
"""

try s.write(toFile: hppPath, atomically: true, encoding: .utf8)
