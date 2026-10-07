import Foundation

enum SemanticMaskRefinement {
    static func refine(_ alpha: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 2, height > 2, alpha.count == width * height else { return alpha }
        let hasSoftAlpha = alpha.contains { $0 > 0 && $0 < 255 }
        let passes = hasSoftAlpha ? 1 : 2
        var current = alpha
        for _ in 0..<passes {
            var next = current
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    var lo: UInt8 = 255, hi: UInt8 = 0, sum = 0
                    for yy in (y - 1)...(y + 1) {
                        for xx in (x - 1)...(x + 1) {
                            let v = current[yy * width + xx]
                            lo = min(lo, v); hi = max(hi, v); sum += Int(v)
                        }
                    }
                    if lo != hi { next[i] = UInt8(clamping: Int((Double(sum) / 9.0).rounded())) }
                }
            }
            current = next
        }
        return current
    }
}
