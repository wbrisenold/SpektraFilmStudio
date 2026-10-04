import Foundation

enum ExportPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case studio = "Studio & Web"
    case social = "Social Media"
    var id: String { rawValue }
}

struct ExportPresetDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: ExportPresetCategory
    let detail: String
    let source: String
    let format: ExportFormat?
    let jpegQuality: Double?
    let tiff16Bit: Bool?
    let preserveMetadata: Bool?
    let stripGPS: Bool?
    let resizeMode: ExportResizeMode
    let width: Int
    let height: Int
    let longEdge: Int
    let dontEnlarge: Bool

    func applying(to existing: ExportSettings) -> ExportSettings {
        var value = existing
        if let format { value.format = format }
        if let jpegQuality { value.jpegQuality = jpegQuality }
        if let tiff16Bit { value.tiff16Bit = tiff16Bit }
        if let preserveMetadata { value.preserveMetadata = preserveMetadata }
        if let stripGPS { value.stripGPS = stripGPS }
        value.resizeMode = resizeMode
        value.resizeWidth = width
        value.resizeHeight = height
        value.resizeLongEdge = longEdge
        value.dontEnlarge = dontEnlarge
        return value
    }

    static let all: [ExportPresetDefinition] = [
        .init(
            id: "rapidraw-hq", name: "High Quality", category: .studio,
            detail: "JPEG 95 · full size · metadata kept",
            source: "RapidRAW default High Quality preset",
            format: .jpeg, jpegQuality: 0.95, tiff16Bit: nil,
            preserveMetadata: true, stripGPS: false,
            resizeMode: .none, width: 2048, height: 2048, longEdge: 2048, dontEnlarge: true
        ),
        .init(
            id: "rapidraw-web", name: "Fast Web", category: .studio,
            detail: "JPEG 80 · 2048 px wide · no enlargement · metadata removed",
            source: "RapidRAW default Fast (Web) preset",
            format: .jpeg, jpegQuality: 0.80, tiff16Bit: nil,
            preserveMetadata: false, stripGPS: true,
            resizeMode: .width, width: 2048, height: 2048, longEdge: 2048, dontEnlarge: true
        ),
        .init(
            id: "tiff16-master", name: "16-bit TIFF Master", category: .studio,
            detail: "TIFF 16-bit · full size · metadata kept",
            source: "SpektraFilm verified 16-bit TIFF path",
            format: .tiff, jpegQuality: nil, tiff16Bit: true,
            preserveMetadata: true, stripGPS: false,
            resizeMode: .none, width: 2048, height: 2048, longEdge: 2048, dontEnlarge: true
        ),

        // Social-media dimensions are sourced from OpenPost's open-source image editor presets.
        // These presets intentionally keep the user's chosen file format/quality; only delivery
        // dimensions and no-upscale policy are changed. The current crop determines composition.
        .social(id: "instagram-square", name: "Instagram Square", width: 1080, height: 1080),
        .social(id: "instagram-portrait", name: "Instagram Portrait", width: 1080, height: 1350),
        .social(id: "story-reel-tiktok", name: "Story / Reel / TikTok", width: 1080, height: 1920),
        .social(id: "linkedin-square", name: "LinkedIn Square", width: 1200, height: 1200),
        .social(id: "linkedin-landscape", name: "LinkedIn Landscape", width: 1200, height: 627),
        .social(id: "x-landscape", name: "X Landscape", width: 1600, height: 900),
        .social(id: "youtube-thumbnail", name: "YouTube Thumbnail", width: 1280, height: 720),
    ]

    private static func social(id: String, name: String, width: Int, height: Int) -> ExportPresetDefinition {
        .init(
            id: id, name: name, category: .social,
            detail: "Fit inside \(width) × \(height) · preserve aspect · no enlargement",
            source: "OpenPost open-source image editor preset dimensions",
            format: nil, jpegQuality: nil, tiff16Bit: nil,
            preserveMetadata: nil, stripGPS: nil,
            resizeMode: .fitBox, width: width, height: height, longEdge: max(width, height), dontEnlarge: true
        )
    }

    static func preset(id: String) -> ExportPresetDefinition? { all.first { $0.id == id } }
}
