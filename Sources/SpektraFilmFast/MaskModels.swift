import Foundation

enum MaskBlendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case add = "Add"
    case subtract = "Subtract"
    case intersect = "Intersect"
    var id: String { rawValue }
}

enum MaskSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case radial = "Radial"
    case linearGradient = "Linear Gradient"
    case raster = "Raster"
    var id: String { rawValue }
}

struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    init(x: Double = 0.5, y: Double = 0.5) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

struct RadialMaskGeometry: Codable, Equatable, Hashable, Sendable {
    var center = NormalizedPoint()
    var radiusX: Double = 0.25
    var radiusY: Double = 0.25
    var rotationDegrees: Double = 0
}

struct LinearGradientMaskGeometry: Codable, Equatable, Hashable, Sendable {
    var start = NormalizedPoint(x: 0.25, y: 0.5)
    var end = NormalizedPoint(x: 0.75, y: 0.5)
}

/// Self-contained 8-bit raster payload. RLE keeps project JSON reasonably small for
/// painted masks while avoiding external mask files that can be separated from a project.
struct RasterMaskPayload: Codable, Equatable, Hashable, Sendable {
    var width: Int
    var height: Int
    var rle: Data

    init(width: Int, height: Int, alpha: [UInt8]) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.rle = Self.encodeRLE(alpha, expectedCount: self.width * self.height)
    }

    func decodedAlpha() -> [UInt8] {
        Self.decodeRLE(rle, expectedCount: width * height)
    }

    private static func encodeRLE(_ alpha: [UInt8], expectedCount: Int) -> Data {
        let source: [UInt8]
        if alpha.count == expectedCount { source = alpha }
        else {
            var copy = Array(alpha.prefix(expectedCount))
            if copy.count < expectedCount { copy += Array(repeating: 0, count: expectedCount - copy.count) }
            source = copy
        }
        var out = Data()
        var i = 0
        while i < source.count {
            let value = source[i]
            var run = 1
            while i + run < source.count, source[i + run] == value, run < 65535 { run += 1 }
            out.append(UInt8(run & 0xff))
            out.append(UInt8((run >> 8) & 0xff))
            out.append(value)
            i += run
        }
        return out
    }

    private static func decodeRLE(_ data: Data, expectedCount: Int) -> [UInt8] {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(expectedCount)
        var i = 0
        while i + 2 < bytes.count, out.count < expectedCount {
            let run = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            let value = bytes[i + 2]
            if run > 0 { out += Array(repeating: value, count: min(run, expectedCount - out.count)) }
            i += 3
        }
        if out.count < expectedCount { out += Array(repeating: 0, count: expectedCount - out.count) }
        return out
    }
}

struct MaskSourceRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = "Mask"
    var kind: MaskSourceKind = .radial
    var enabled = true
    var inverted = false
    var opacity: Double = 1
    var feather: Double = 0.15
    var blendMode: MaskBlendMode = .add
    var radial: RadialMaskGeometry? = RadialMaskGeometry()
    var linearGradient: LinearGradientMaskGeometry? = nil
    var raster: RasterMaskPayload? = nil

    mutating func normalize() {
        opacity = min(1, max(0, opacity))
        feather = min(1, max(0, feather))
        if kind == .radial, radial == nil { radial = RadialMaskGeometry() }
        if kind == .linearGradient, linearGradient == nil { linearGradient = LinearGradientMaskGeometry() }
    }
}

struct MaskStackRecord: Codable, Equatable, Hashable, Sendable {
    var sources: [MaskSourceRecord] = []

    var isEffectivelyFullFrame: Bool { sources.filter(\.enabled).isEmpty }
}

/// One non-destructive local grade. The grade carries its own ordered mask stack,
/// mirroring Alcedo's grade -> mask stack -> coverage -> composite architecture.
struct LocalGradeRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = "Local Grade"
    var enabled = true
    var opacity: Double = 1
    var values: [String: ParameterValue] = [:]
    var tone: ToneSettings? = nil
    var colorDensity: ColorDensitySettings? = nil
    var masks = MaskStackRecord()

    mutating func normalize() {
        opacity = min(1, max(0, opacity))
        for index in masks.sources.indices { masks.sources[index].normalize() }
    }
}
