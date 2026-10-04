import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ExportFailure: Sendable, Equatable {
    let fileName: String
    let message: String
}

enum ExportWriterError: LocalizedError {
    case cannotCreateImage
    case cannotCreateDestination(String)
    case encoderFinalizeFailed
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateImage: "Could not construct the export image buffer."
        case .cannotCreateDestination(let type): "ImageIO could not create a \(type) encoder on this Mac."
        case .encoderFinalizeFailed: "Image encoder failed while finalizing the file."
        case .verificationFailed(let reason): "Export verification failed: \(reason)"
        }
    }
}

enum ExportWriter {
    static func write(
        output: PixelBufferF32,
        look: RenderLook,
        sourceURL: URL,
        destination: URL,
        settings: ExportSettings
    ) throws {
        let profile = OutputColorProfile.forLook(look)
        let image: CGImage
        if settings.format == .tiff && settings.tiff16Bit {
            guard let cg = output.makeCGImage16(colorSpace: profile.cgColorSpace) else { throw ExportWriterError.cannotCreateImage }
            image = cg
        } else {
            guard let cg = output.makeCGImage8(colorSpace: profile.cgColorSpace) else { throw ExportWriterError.cannotCreateImage }
            image = cg
        }

        let type: CFString
        switch settings.format {
        case .jpeg: type = UTType.jpeg.identifier as CFString
        case .heic: type = UTType.heic.identifier as CFString
        case .tiff: type = UTType.tiff.identifier as CFString
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        defer { try? fm.removeItem(at: temp) }

        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else {
            throw ExportWriterError.cannotCreateDestination(settings.format.rawValue)
        }

        var properties = settings.preserveMetadata ? sourceMetadata(url: sourceURL, stripGPS: settings.stripGPS) : [:]
        // The rendered pixels are already physically rotated. Never carry a source
        // EXIF orientation that would rotate them a second time in another application.
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = output.width
        properties[kCGImagePropertyPixelHeight] = output.height
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = output.width
            exif[kCGImagePropertyExifPixelYDimension] = output.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if settings.format == .jpeg || settings.format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.1, settings.jpegQuality))
        }
        if settings.format == .tiff {
            properties[kCGImagePropertyDepth] = settings.tiff16Bit ? 16 : 8
        }

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportWriterError.encoderFinalizeFailed }

        try verify(url: temp, expectedWidth: output.width, expectedHeight: output.height, require16Bit: settings.format == .tiff && settings.tiff16Bit)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }

        // Verify the final path too. This catches filesystem/replace failures instead
        // of reporting a studio export as successful when nothing usable was written.
        try verify(url: destination, expectedWidth: output.width, expectedHeight: output.height, require16Bit: settings.format == .tiff && settings.tiff16Bit)
    }

    private static func sourceMetadata(url: URL, stripGPS: Bool) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var result = raw
        result.removeValue(forKey: kCGImagePropertyPixelWidth)
        result.removeValue(forKey: kCGImagePropertyPixelHeight)
        result.removeValue(forKey: kCGImagePropertyOrientation)
        // Never carry the source file's profile/depth claims onto pixels rendered
        // into a potentially different Spektrafilm output space.
        result.removeValue(forKey: kCGImagePropertyProfileName)
        result.removeValue(forKey: kCGImagePropertyDepth)
        result.removeValue(forKey: kCGImagePropertyColorModel)
        if stripGPS {
            result.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }
        return result
    }

    private static func verify(url: URL, expectedWidth: Int, expectedHeight: Int, require16Bit: Bool) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 0 else { throw ExportWriterError.verificationFailed("file is empty") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportWriterError.verificationFailed("ImageIO cannot decode the written file")
        }
        guard image.width == expectedWidth && image.height == expectedHeight else {
            throw ExportWriterError.verificationFailed("decoded dimensions are \(image.width)×\(image.height), expected \(expectedWidth)×\(expectedHeight)")
        }
        if require16Bit && image.bitsPerComponent < 16 {
            throw ExportWriterError.verificationFailed("TIFF decoded at \(image.bitsPerComponent)-bit instead of 16-bit")
        }
    }
}

actor ExportEngine {
    func write(
        output: PixelBufferF32,
        look: RenderLook,
        sourceURL: URL,
        destination: URL,
        settings: ExportSettings
    ) throws {
        try autoreleasepool {
            try ExportWriter.write(
                output: output,
                look: look,
                sourceURL: sourceURL,
                destination: destination,
                settings: settings
            )
        }
    }
}
