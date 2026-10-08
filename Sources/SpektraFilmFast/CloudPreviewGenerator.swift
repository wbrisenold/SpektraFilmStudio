import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers


struct CloudPreviewImage: @unchecked Sendable {
    let value: CGImage
}

actor CloudPreviewWriter {
    static let shared = CloudPreviewWriter()

    func write(_ image: CloudPreviewImage, destination: URL) {
        try? CloudPreviewGenerator.writeJPEG(image: image.value, destination: destination)
    }
}

enum CloudPreviewGenerator {
    static func writeJPEG(
        image: CGImage,
        destination: URL,
        quality: Double = 0.82
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")

        guard let dest = CGImageDestinationCreateWithURL(
            temp as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "SpektraFilm.CloudPreview", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create rendered cloud preview destination."])
        }
        CGImageDestinationAddImage(
            dest,
            image,
            [kCGImageDestinationLossyCompressionQuality: min(1, max(0.2, quality))] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "SpektraFilm.CloudPreview", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Could not finalize rendered cloud preview."])
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    static func writeJPEG(
        source: URL,
        destination: URL,
        maxPixel: Int = 1280,
        quality: Double = 0.82
    ) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw NSError(domain: "SpektraFilm.CloudPreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open \(source.lastPathComponent) for cloud preview."])
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(256, maxPixel),
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary
        ) else {
            throw NSError(domain: "SpektraFilm.CloudPreview", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create a cloud preview for \(source.lastPathComponent)."])
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")

        guard let dest = CGImageDestinationCreateWithURL(
            temp as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "SpektraFilm.CloudPreview", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create cloud preview destination."])
        }

        CGImageDestinationAddImage(
            dest,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: min(1, max(0.2, quality))] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "SpektraFilm.CloudPreview", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not finalize cloud preview."])
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
