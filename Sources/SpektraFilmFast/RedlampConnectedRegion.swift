// Redlamp RemovalRegion.largestPiece, MPL-2.0; see Resources/Redlamp-MPL-2.0.txt.
import Foundation
enum RemovalRegion {
    static func dilated(_ region: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        let share = 0.5 / Float((2 * radius + 1) * (2 * radius + 1))
        return BoxFilter.blur(region.map { $0 ? Float(1) : 0 }, width: width, height: height, radius: radius)
            .map { $0 > share }
    }

    static func largestPiece(_ region: [Bool], width: Int, height: Int) -> [Bool] {
        var label = [Int32](repeating: -1, count: region.count)
        var (best, most, next): (Int32, Int, Int32) = (-1, 0, 0)
        var stack: [Int] = []
        for start in region.indices where region[start] && label[start] < 0 {
            label[start] = next
            stack.append(start)
            var count = 0
            while let index = stack.popLast() {
                count += 1
                let (x, y) = (index % width, index / width)
                for ny in max(y - 1, 0) ... min(y + 1, height - 1) {
                    for nx in max(x - 1, 0) ... min(x + 1, width - 1) where region[ny * width + nx] {
                        let neighbour = ny * width + nx
                        guard label[neighbour] < 0 else { continue }
                        label[neighbour] = next
                        stack.append(neighbour)
                    }
                }
            }
            if count > most {
                (best, most) = (next, count)
            }
            next += 1
        }
        guard best >= 0 else { return [Bool](repeating: false, count: region.count) }
        return label.map { $0 == best }
    }

}
