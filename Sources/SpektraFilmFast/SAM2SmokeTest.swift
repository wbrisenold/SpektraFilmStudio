import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Run against Meta's public truck example, supplied as --sam2-fixture <path>.
enum SAM2SmokeTest {
    static func run(directory: URL? = nil) -> Int32 {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--sam2-fixture"), index + 1 < CommandLine.arguments.count,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[index + 1]) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NSError(domain: "SAM2 smoke fixture", code: 1) }
            let model = try SAM2TinySegmenter(directory: directory)
            let start = Date()
            let alpha = try model.mask(image: image, point: CGPoint(x: 0.6, y: 0.45))
            guard alpha.count == image.width * image.height else { throw NSError(domain: "SAM2 mask size", code: 2) }
            func sample(_ x: Double, _ y: Double) -> UInt8 { alpha[Int(y * Double(image.height)) * image.width + Int(x * Double(image.width))] }
            let cached = try model.mask(image: image, point: CGPoint(x: 0.6, y: 0.45))
            guard alpha == cached else { throw NSError(domain: "SAM2 repeated prompt", code: 4) }
            let wall = try model.mask(image: image, point: CGPoint(x: 0.5, y: 0.1))
            guard wall != alpha, wall[Int(0.1 * Double(image.height)) * image.width + image.width / 2] > 200 else { throw NSError(domain: "SAM2 changed prompt", code: 7) }
            do {
                _ = try model.mask(image: image, point: CGPoint(x: CGFloat.nan, y: 0))
                throw NSError(domain: "SAM2 accepted invalid point", code: 5)
            } catch let error as NSError where error.domain == "Spektra.SAM2" { }
            let data = Data(alpha)
            if let provider = CGDataProvider(data: data as CFData), let cg = CGImage(width: image.width, height: image.height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                let writer = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[index + 1] + ".mask.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(writer, cg, nil)
                guard CGImageDestinationFinalize(writer) else { throw NSError(domain: "SAM2 mask image", code: 6) }
            }
            print("SAM2 coverage: truck=\(sample(0.6, 0.45)), wall=\(sample(0.3, 0.1)), ground=\(sample(0.5, 0.95)), selected=\(alpha.filter { $0 > 128 }.count)/\(alpha.count)")
            guard sample(0.6, 0.45) > 200, sample(0.3, 0.1) < 30, sample(0.5, 0.95) < 30,
                  alpha.filter({ $0 > 128 }).count > alpha.count / 50,
                  alpha.filter({ $0 > 128 }).count < alpha.count / 3 else { throw NSError(domain: "SAM2 semantic coverage/orientation", code: 3) }
            print("SAM2_SMOKE_PASS: real Intel inference, truck-door coverage, background rejection, orientation, repeat/changed prompt and invalid input; seconds=\(Date().timeIntervalSince(start))")
            return 0
        } catch {
            print("SAM2_SMOKE_FAIL: \(error)")
            return 24
        }
    }
}
