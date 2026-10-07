import Foundation

/// One canonical mask representation for every selection, local grade, overlay,
/// scope and export path. Coverage is row-major UInt8: 0 = excluded, 255 = selected.
struct CanonicalMaskBuffer: Sendable, Equatable {
    let width: Int
    let height: Int
    var coverage: [UInt8]

    init(width: Int, height: Int, coverage: [UInt8]) {
        precondition(width > 0 && height > 0)
        precondition(coverage.count == width * height)
        self.width = width
        self.height = height
        self.coverage = coverage
    }

    var selectedFraction: Double {
        guard !coverage.isEmpty else { return 0 }
        let total = coverage.reduce(UInt64(0)) { $0 + UInt64($1) }
        return Double(total) / (255.0 * Double(coverage.count))
    }

    func overlayRGBA(
        red: UInt8 = 0,
        green: UInt8 = 225,
        blue: UInt8 = 255,
        maximumAlpha: UInt8 = 150
    ) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: coverage.count * 4)
        for i in coverage.indices {
            let o = i * 4
            rgba[o] = red
            rgba[o + 1] = green
            rgba[o + 2] = blue
            rgba[o + 3] = UInt8((UInt16(coverage[i]) * UInt16(maximumAlpha) + 127) / 255)
        }
        return rgba
    }
}
