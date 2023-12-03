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
        let headerSize = 15
        FileManager.default.createFile(atPath: destination, contents: nil, attributes: nil)
        guard let writer = try? FileHandle(forWritingTo: URL(fileURLWithPath: destination)) else { fatalError() }
        defer { writer.closeFile() }
        for file in files {
            guard let reader = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) else { fatalError() }
            _ = try? reader.read(upToCount: headerSize)
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

struct Weight {
    var a: simd_float3
    var b: simd_float3
}

struct Texture {
    let index: Int
    let mapping: simd_float2
    let wx: Weight
    let wy: Weight

    init(_ index: Int, _ mapping: simd_float2, _ wx: Weight, _ wy: Weight) {
        self.index = index
        self.mapping = mapping
        self.wx = wx
        self.wy = wy
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

func edgeFunction(_ v1: simd_float2, _ v2: simd_float2, _ v3: simd_float2) -> Float {
    (v3.x - v1.x) * (v1.y - v2.y) + (v3.y - v1.y) * (v2.x - v1.x)
}

func midY(_ a: simd_float2, _ b: simd_float2, _ c: simd_float2) -> simd_float2 {
    simd_float2(a.x, (c.y - b.y) * (a.x - b.x) / (c.x - b.x) + b.y)
}

func midX(_ a: simd_float2, _ b: simd_float2, _ c: simd_float2) -> simd_float2 {
    simd_float2((c.x - b.x) * (a.y - b.y) / (c.y - b.y) + b.x, a.y)
}

func textureWeight(_ a: simd_float2, _ b: simd_float2, _ c: simd_float2) -> (Weight, Weight) {
    let area = edgeFunction(a, b, c)
    let fromX: simd_float2
    let toX: simd_float2
    if b.y < a.y && a.y < c.y || c.y < a.y && a.y < b.y {
        fromX = a
        toX = midX(a, b, c)
    } else if a.y < b.y && b.y < c.y || c.y < b.y && b.y < a.y {
        fromX = b
        toX = midX(b, a, c)
    } else {
        fromX = c
        toX = midX(c, a, b)
    }
    let xWeight = Weight(a: simd_float3(edgeFunction(b, c, fromX), edgeFunction(c, a, fromX), edgeFunction(a, b, fromX)) / area,
                         b: simd_float3(edgeFunction(b, c, toX), edgeFunction(c, a, toX), edgeFunction(a, b, toX)) / area)
    let fromY: simd_float2
    let toY: simd_float2
    if b.x < a.x && a.x < c.x || c.x < a.x && a.x < b.x {
        fromY = a
        toY = midY(a, b, c)
    } else if a.x < b.x && b.x < c.x || c.x < b.x && b.x < a.x {
        fromY = b
        toY = midY(b, a, c)
    } else {
        fromY = c
        toY = midY(c, a, b)
    }
    let yWeight = Weight(a: simd_float3(edgeFunction(b, c, fromY), edgeFunction(c, a, fromY), edgeFunction(a, b, fromY)) / area,
                         b: simd_float3(edgeFunction(b, c, toY), edgeFunction(c, a, toY), edgeFunction(a, b, toY)) / area)
    return (xWeight, yWeight)
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
    let p = simd_float3(0, 0, -5)
    v = v.map { r * $0 + p }
    vertices.append(contentsOf: v)
    vertexIndexes.append(contentsOf: [
        0, 1, 2,
    ])
    let j = attributes.count
    let t1 = simd_float2(0, sqrt(3)/2)
    let t2 = simd_float2(0.5, 0)
    let t3 = simd_float2(1, sqrt(3)/2)
    let (wx, wy) = textureWeight(t1, t2, t3)
    attributes.append(contentsOf: [
//        VertexAttribute(normal(v, 0, 1, 2), .color(red)),
//        VertexAttribute(normal(v, 0, 1, 2), .color(orange)),
//        VertexAttribute(normal(v, 0, 1, 2), .color(blue)),
        VertexAttribute(normal(v, 0, 1, 2), .texture(Texture(0, t1, wx, wy))),
        VertexAttribute(normal(v, 0, 1, 2), .texture(Texture(0, t2, wx, wy))),
        VertexAttribute(normal(v, 0, 1, 2), .texture(Texture(0, t3, wx, wy))),
    ])
    attributeIndexes.append(contentsOf: (j..<(j + 3)))
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
            s += ".texture(Texture(\(t.index), simd_float2(\(t.mapping.x), \(t.mapping.y)), TextureWeight(simd_float3(\(t.wx.a.x), \(t.wx.a.y), \(t.wx.a.z)), simd_float3(\(t.wx.b.x), \(t.wx.b.y), \(t.wx.b.z))), TextureWeight(simd_float3(\(t.wy.a.x), \(t.wy.a.y), \(t.wy.a.z)), simd_float3(\(t.wy.b.x), \(t.wy.b.y), \(t.wy.b.z)))))),\n"
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
