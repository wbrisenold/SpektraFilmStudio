import Foundation
import RawSpeedBridge

/// RawSpeed-based RAW decoder that replaces CIRAWFilter
/// Provides linear, scene-referred, camera RGB output matching Darktable's pipeline
actor RawSpeedDecoder {
    private var decoderRef: RawSpeedDecoderRef?
    private let url: URL
    private var metadata: RawSpeedMetadata?
    private var rawImage: RawSpeedImage?
    
    // Non-isolated storage for deinit access (unsafe but necessary for C resource cleanup)
    nonisolated(unsafe) var _decoderRef: RawSpeedDecoderRef?
    nonisolated(unsafe) var _rawImage: RawSpeedImage?
    
    enum DecoderError: Error, CustomStringConvertible {
        case unsupportedFormat
        case loadFailed(String)
        case unsupportedFeature
        case fileCorrupted
        case memory
        case cameraNotSupported
        case internalError(String)
        
        var description: String {
            switch self {
            case .unsupportedFormat: return "Unsupported RAW format"
            case .loadFailed(let msg): return "Load failed: \(msg)"
            case .unsupportedFeature: return "Unsupported feature"
            case .fileCorrupted: return "File corrupted"
            case .memory: return "Out of memory"
            case .cameraNotSupported: return "Camera not supported"
            case .internalError(let msg): return "Internal error: \(msg)"
            }
        }
    }
    
    init(url: URL) {
        self.url = url
        self._decoderRef = nil
        self._rawImage = nil
    }
    
    deinit {
        // Synchronous cleanup for deinit - use non-isolated storage
        if let decoder = _decoderRef {
            RawSpeedDecoderDestroy(decoder)
        }
        if let image = _rawImage {
            image.freeCMemory()
        }
    }
    
    func open() throws {
        var cError: RawSpeedError = RawSpeedError_None
        decoderRef = RawSpeedDecoderCreate(url.path, &cError)
        _decoderRef = decoderRef
        
        guard let decoder = decoderRef else {
            throw mapError(cError)
        }
        
        var cMeta = RawSpeedBridge.RawSpeedMetadata()
        let metaError = RawSpeedDecoderGetMetadata(decoder, &cMeta)
        guard metaError == RawSpeedError_None else {
            throw DecoderError.internalError("Failed to get metadata")
        }
        
        metadata = RawSpeedMetadata(from: cMeta)
        
        // Check camera support
        if let meta = metadata, !meta.cameraSupported {
            throw DecoderError.cameraNotSupported
        }
    }
    
    func getMetadata() -> RawSpeedMetadata? {
        return metadata
    }
    
    func decode() throws -> RawSpeedImage {
        guard let decoder = decoderRef else {
            throw DecoderError.internalError("Decoder not initialized")
        }
        
        var cImage = RawSpeedBridge.RawSpeedImage()
        let error = RawSpeedDecoderDecode(decoder, &cImage)
        guard error == RawSpeedError_None else {
            throw mapError(error)
        }
        
        rawImage = RawSpeedImage(from: cImage)
        _rawImage = rawImage
        return rawImage!
    }
    
    func applyWhiteBalance(to image: inout RawSpeedImage) throws {
        guard let decoder = decoderRef else {
            throw DecoderError.internalError("Decoder not initialized")
        }
        
        var cImage = RawSpeedBridge.RawSpeedImage()
        // Convert back to C struct (simplified - in practice we'd keep the C struct)
        // For now, this is a placeholder
        let error = RawSpeedDecoderApplyWhiteBalance(decoder, &cImage)
        guard error == RawSpeedError_None else {
            throw mapError(error)
        }
    }
    
    func close() {
        if let decoder = decoderRef {
            RawSpeedDecoderDestroy(decoder)
            decoderRef = nil
            _decoderRef = nil
        }
        if let image = rawImage {
            image.freeCMemory()
            rawImage = nil
            _rawImage = nil
        }
    }
    
    private func mapError(_ error: RawSpeedError) -> DecoderError {
        switch error {
        case RawSpeedError_UnsupportedFormat: return .unsupportedFormat
        case RawSpeedError_LoadFailed: return .loadFailed("Unknown error")
        case RawSpeedError_UnsupportedFeature: return .unsupportedFeature
        case RawSpeedError_FileCorrupted: return .fileCorrupted
        case RawSpeedError_Memory: return .memory
        case RawSpeedError_CameraNotSupported: return .cameraNotSupported
        case RawSpeedError_Internal: return .internalError("Internal error")
        default: return .internalError("Unknown error code: \(error.rawValue)")
        }
    }
}

/// Swift-friendly wrapper around RawSpeedMetadata
struct RawSpeedMetadata {
    let cameraMaker: String
    let cameraModel: String
    let cameraAlias: String
    let rawBlackLevel: Float
    let rawWhitePoint: Float
    let rawBlackLevelSeparate: [Float]
    let cropX: Int32
    let cropY: Int32
    let cropRight: Int32
    let cropBottom: Int32
    let width: Int32
    let height: Int32
    let filters: UInt32
    let xtrans: [[UInt8]]
    let orientation: Int32
    let colorMatrix: [Float]
    let wbCoeffs: [Float]
    let isoSpeed: Float
    let exposureTime: Float
    let aperture: Float
    let focalLength: Float
    let is4Bayer: Bool
    let cameraSupported: Bool
    
    init(from cMetadata: RawSpeedBridge.RawSpeedMetadata) {
        // Convert fixed-size C char arrays to Strings
        self.cameraMaker = withUnsafePointer(to: cMetadata.camera_maker) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        self.cameraModel = withUnsafePointer(to: cMetadata.camera_model) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        self.cameraAlias = withUnsafePointer(to: cMetadata.camera_alias) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        self.rawBlackLevel = cMetadata.raw_black_level
        self.rawWhitePoint = cMetadata.raw_white_point
        // raw_black_level_separate is a tuple (Float, Float, Float, Float)
        self.rawBlackLevelSeparate = [cMetadata.raw_black_level_separate.0, cMetadata.raw_black_level_separate.1, cMetadata.raw_black_level_separate.2, cMetadata.raw_black_level_separate.3]
        self.cropX = cMetadata.crop_x
        self.cropY = cMetadata.crop_y
        self.cropRight = cMetadata.crop_right
        self.cropBottom = cMetadata.crop_bottom
        self.width = cMetadata.width
        self.height = cMetadata.height
        self.filters = cMetadata.filters
        // xtrans is a tuple of 6 tuples of 6 UInt8 - convert manually
        self.xtrans = [
            [cMetadata.xtrans.0.0, cMetadata.xtrans.0.1, cMetadata.xtrans.0.2, cMetadata.xtrans.0.3, cMetadata.xtrans.0.4, cMetadata.xtrans.0.5],
            [cMetadata.xtrans.1.0, cMetadata.xtrans.1.1, cMetadata.xtrans.1.2, cMetadata.xtrans.1.3, cMetadata.xtrans.1.4, cMetadata.xtrans.1.5],
            [cMetadata.xtrans.2.0, cMetadata.xtrans.2.1, cMetadata.xtrans.2.2, cMetadata.xtrans.2.3, cMetadata.xtrans.2.4, cMetadata.xtrans.2.5],
            [cMetadata.xtrans.3.0, cMetadata.xtrans.3.1, cMetadata.xtrans.3.2, cMetadata.xtrans.3.3, cMetadata.xtrans.3.4, cMetadata.xtrans.3.5],
            [cMetadata.xtrans.4.0, cMetadata.xtrans.4.1, cMetadata.xtrans.4.2, cMetadata.xtrans.4.3, cMetadata.xtrans.4.4, cMetadata.xtrans.4.5],
            [cMetadata.xtrans.5.0, cMetadata.xtrans.5.1, cMetadata.xtrans.5.2, cMetadata.xtrans.5.3, cMetadata.xtrans.5.4, cMetadata.xtrans.5.5]
        ]
        self.orientation = cMetadata.orientation
        // color_matrix is a tuple of 12 Floats
        self.colorMatrix = [
            cMetadata.color_matrix.0, cMetadata.color_matrix.1, cMetadata.color_matrix.2, cMetadata.color_matrix.3,
            cMetadata.color_matrix.4, cMetadata.color_matrix.5, cMetadata.color_matrix.6, cMetadata.color_matrix.7,
            cMetadata.color_matrix.8, cMetadata.color_matrix.9, cMetadata.color_matrix.10, cMetadata.color_matrix.11
        ]
        // wb_coeffs is a tuple of 4 Floats
        self.wbCoeffs = [cMetadata.wb_coeffs.0, cMetadata.wb_coeffs.1, cMetadata.wb_coeffs.2, cMetadata.wb_coeffs.3]
        self.isoSpeed = cMetadata.iso_speed
        self.exposureTime = cMetadata.exposure_time
        self.aperture = cMetadata.aperture
        self.focalLength = cMetadata.focal_length
        self.is4Bayer = cMetadata.is_4bayer
        self.cameraSupported = cMetadata.camera_supported
    }
}

/// Swift-friendly wrapper around RawSpeedImage
struct RawSpeedImage {
    let data: [Float]
    let width: Int
    let height: Int
    let channels: Int
    let rowStride: Int
    // Track the original C pointer for proper cleanup
    private let cPointer: UnsafeMutableRawPointer?
    
    init(from cImage: RawSpeedBridge.RawSpeedImage) {
        let count = Int(cImage.width * cImage.height * cImage.channels)
        let buffer = UnsafeBufferPointer(start: cImage.data, count: count)
        self.data = Array(buffer)
        self.width = Int(cImage.width)
        self.height = Int(cImage.height)
        self.channels = Int(cImage.channels)
        self.rowStride = Int(cImage.row_stride)
        // Cast Float pointer to raw pointer for free()
        self.cPointer = UnsafeMutableRawPointer(cImage.data)
    }
    
    /// Create a deep copy (for when we need to own the data)
    func copy() -> RawSpeedImage {
        let copy = RawSpeedImage(
            data: data,
            width: width,
            height: height,
            channels: channels,
            rowStride: rowStride
        )
        return copy
    }
    
    private init(data: [Float], width: Int, height: Int, channels: Int, rowStride: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.channels = channels
        self.rowStride = rowStride
        self.cPointer = nil
    }
    
    /// Free the underlying C memory if we own it
    func freeCMemory() {
        if let ptr = cPointer {
            free(ptr)
        }
    }
}

/// Extension to check if a file extension is supported
extension RawSpeedDecoder {
    static func isExtensionSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return RawSpeedIsExtensionSupported(ext)
    }
    
    static func getSupportedExtensions() -> [String] {
        let cString = RawSpeedGetSupportedExtensions()
        guard let cString = cString else { return [] }
        return String(cString: cString).components(separatedBy: ",")
    }
}