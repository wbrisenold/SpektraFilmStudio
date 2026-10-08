import Foundation

extension UTTypeNames {
    static let projectExtension = "spektrafilm"
    static let presetExtension = "sfpreset"
}

import UniformTypeIdentifiers

extension UTType {
    static var spektrafilmProject: UTType {
        UTType(exportedAs: "org.spektrafilm.project", conformingTo: .data)
    }
    static var spektrafilmPreset: UTType {
        UTType(exportedAs: "com.spektrafilm.preset")
    }
}

enum UTTypeNames {}

enum WorkspacePage: String, Codable, CaseIterable, Identifiable, Sendable {
    case library = "Library"
    case cull = "Cull"
    case proofs = "Proofs"
    case edit = "Edit"
    case export = "Export"

    var id: String { rawValue }
    var title: String { rawValue }
    var systemImage: String {
        switch self {
        case .library: "photo.on.rectangle.angled"
        case .cull: "checkmark.rectangle.stack"
        case .proofs: "person.2.crop.square.stack"
        case .edit: "slider.horizontal.3"
        case .export: "square.and.arrow.up"
        }
    }
}

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case project = "Project"
    case standalone = "Standalone Photo Mode"
    var id: String { rawValue }
}



enum PhotoColorLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case red = "Red", yellow = "Yellow", green = "Green", blue = "Blue", purple = "Purple"
    var id: String { rawValue }
}

enum CullRecommendation: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep = "Keep"
    case review = "Review"
    case reject = "Reject"
    var id: String { rawValue }
}

struct CullAnalysisRecord: Codable, Equatable, Hashable, Sendable {
    var score: Double
    var recommendation: CullRecommendation
    var sharpness: Double
    var faceSharpness: Double
    var exposureQuality: Double
    var highlightClipPercent: Double
    var shadowClipPercent: Double
    var noiseEstimate: Double
    var faceCount: Int
    var possibleBlink: Bool
    var perceptualHash: UInt64
    var stackID: UUID?
    var stackRank: Int?
    var stackCount: Int?
    // Optional: synthesized Codable remains backward-compatible with old cull cache records.
    var faceCaptureQuality: Double? = nil
    var aestheticScore: Double? = nil
    var reasons: [String]
    var analyzedAt: Date
}

enum ScopeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case histogram = "Histogram"
    case waveform = "Waveform"
    case parade = "RGB Parade"
    case vectorscope = "Vectorscope"
    case skinVectorscope = "Skin Vector"
    case saturation = "Saturation"
    case falseColor = "False Color"
    case chromaticity = "CIE xy"
    var id: String { rawValue }
}

enum ProjectFlag: String, Codable, CaseIterable, Identifiable, Sendable {
    case unflagged, picked, rejected
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ProjectSortMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case importDate = "Import Date"
    case fileName = "File Name"
    case rating = "Rating"
    case captureDate = "Capture Date"
    case camera = "Camera"
    case lens = "Lens"
    case aiScore = "Cull Score"
    var id: String { rawValue }
}

enum RawWhiteBalanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case asShot = "As Shot"
    case auto = "Auto"
    case custom = "Custom"
    var id: String { rawValue }
}

struct WhiteBalanceQuickPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let temperatureOffsetMired: Double
    let tintOffset: Double
    let help: String

    /// Technical relative presets. These never force an absolute Kelvin value; they start from
    /// the selected image's resolved As Shot or Auto neutral and apply a mired/tint delta.
    static let technicalPresets: [WhiteBalanceQuickPreset] = [
        .init(
            id: "neutral",
            name: "Neutral",
            temperatureOffsetMired: 0,
            tintOffset: 0,
            help: "Uses this photo's As Shot or Auto white balance with no extra shift."
        ),
        .init(
            id: "warmer",
            name: "Warmer",
            temperatureOffsetMired: -12,
            tintOffset: 0,
            help: "Makes this photo modestly warmer while keeping its own starting white balance."
        ),
        .init(
            id: "cooler",
            name: "Cooler",
            temperatureOffsetMired: 12,
            tintOffset: 0,
            help: "Makes this photo modestly cooler while keeping its own starting white balance."
        ),
        .init(
            id: "fix-green",
            name: "Fix Green Cast",
            temperatureOffsetMired: 0,
            tintOffset: 10,
            help: "Adds a small magenta correction to reduce a green color cast."
        ),
        .init(
            id: "fix-magenta",
            name: "Fix Magenta Cast",
            temperatureOffsetMired: 0,
            tintOffset: -10,
            help: "Adds a small green correction to reduce a magenta color cast."
        )
    ]

    /// SpektraFilm creative WB recipes. These are intentionally original creative recipes rather
    /// than pretending there is a standardized open-source numeric definition for moods such as
    /// Golden Hour or Blue Hour. They remain scene-relative by applying offsets to As Shot/Auto.
    static let creativePresets: [WhiteBalanceQuickPreset] = [
        .init(id: "golden-hour", name: "Golden Hour", temperatureOffsetMired: -25, tintOffset: 4,
              help: "Adds a rich warm glow with a small magenta lift while keeping this photo's own neutral underneath."),
        .init(id: "sunset", name: "Sunset", temperatureOffsetMired: -38, tintOffset: 8,
              help: "Pushes the image noticeably warmer and slightly magenta for deeper sunset color."),
        .init(id: "sunrise", name: "Sunrise", temperatureOffsetMired: -22, tintOffset: 6,
              help: "A softer warm-magenta shift for early-morning light without going as orange as Sunset."),
        .init(id: "blue-hour", name: "Blue Hour", temperatureOffsetMired: 28, tintOffset: 1,
              help: "Cools the image strongly while keeping a slight magenta bias so twilight does not look green."),
        .init(id: "moonlight", name: "Moonlight", temperatureOffsetMired: 36, tintOffset: 4,
              help: "Creates a cooler night feel with enough magenta to keep the result from becoming cyan-green."),
        .init(id: "candlelight", name: "Candlelight", temperatureOffsetMired: -45, tintOffset: 8,
              help: "Adds a strong warm amber feel with a gentle magenta correction for intimate interior light."),
        .init(id: "overcast-warmth", name: "Overcast Warmth", temperatureOffsetMired: -14, tintOffset: 4,
              help: "Takes the cool edge off cloudy light while keeping the scene natural."),
        .init(id: "open-shade", name: "Open Shade", temperatureOffsetMired: -10, tintOffset: 5,
              help: "Warms cool shaded portraits and adds a little magenta to counter the green cast often found in shade."),
        .init(id: "warm-interior", name: "Warm Interior", temperatureOffsetMired: -20, tintOffset: 7,
              help: "Keeps indoor light inviting with a controlled warm-magenta bias."),
        .init(id: "cool-interior", name: "Cool Interior", temperatureOffsetMired: 16, tintOffset: 3,
              help: "Gives interiors a cleaner, cooler feel without pushing neutral surfaces toward green."),
        .init(id: "winter-cool", name: "Winter Cool", temperatureOffsetMired: 24, tintOffset: 2,
              help: "Adds a crisp cool cast suited to snow, winter scenes, and clean modern edits."),
        .init(id: "neon-night", name: "Neon Night", temperatureOffsetMired: 14, tintOffset: 12,
              help: "Cools the scene while adding a visible magenta bias for neon and nightlife color."),
        .init(id: "desert-heat", name: "Desert Heat", temperatureOffsetMired: -32, tintOffset: 3,
              help: "Pushes dry outdoor scenes toward warm amber without making skin excessively pink."),
        .init(id: "forest-cool", name: "Forest Cool", temperatureOffsetMired: 12, tintOffset: -5,
              help: "Adds a cool-green environmental feel for foliage-heavy scenes. Use carefully on skin."),
        .init(id: "film-warm", name: "Film Warm", temperatureOffsetMired: -18, tintOffset: 6,
              help: "A restrained warm-magenta bias designed to sit naturally under the selected film stock."),
        .init(id: "clean-editorial", name: "Clean Editorial", temperatureOffsetMired: 5, tintOffset: 3,
              help: "A very slight cool-magenta correction for a clean, modern neutral look."),
        .init(id: "skin-friendly-warm", name: "Skin-Friendly Warmth", temperatureOffsetMired: -10, tintOffset: 5,
              help: "A gentle warm-magenta shift intended for portraits without heavily changing the environment."),
        .init(id: "snow-day", name: "Snow Day", temperatureOffsetMired: 18, tintOffset: 2,
              help: "Keeps snow and bright winter scenes crisp and cool while avoiding a green cast."),
        .init(id: "late-afternoon", name: "Late Afternoon", temperatureOffsetMired: -18, tintOffset: 2,
              help: "Adds moderate warmth for late-day outdoor light without the stronger Sunset treatment."),
        .init(id: "warm-neutral", name: "Warm Neutral", temperatureOffsetMired: -8, tintOffset: 2,
              help: "A subtle everyday warm shift that works well across a large set of images."),
        .init(id: "cool-neutral", name: "Cool Neutral", temperatureOffsetMired: 8, tintOffset: 2,
              help: "A subtle everyday cool shift that stays close to the image's original neutral."),
        .init(id: "magenta-glow", name: "Magenta Glow", temperatureOffsetMired: -8, tintOffset: 14,
              help: "Adds a creative pink-magenta bias while only slightly warming the image."),
        .init(id: "cyan-night", name: "Cyan Night", temperatureOffsetMired: 30, tintOffset: -6,
              help: "Pushes night scenes cooler with a cyan-green bias for a stylized urban look. Use carefully on skin."),
        .init(id: "amber-room", name: "Amber Room", temperatureOffsetMired: -34, tintOffset: 3,
              help: "Leans strongly warm for lamps, restaurants, receptions, and ambient tungsten interiors.")
    ]

    static let relativePresets: [WhiteBalanceQuickPreset] = technicalPresets + creativePresets
}

enum RawDenoiseMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case auto = "Auto"
    case manual = "Manual"
    var id: String { rawValue }
}

struct RawSettings: Codable, Equatable, Hashable, Sendable {
    var whiteBalanceMode: RawWhiteBalanceMode = .asShot
    var temperature: Double = 5500
    var tint: Double = 0
    var lensCorrection = false
    var temperatureOffsetMired: Double? = nil
    var tintOffset: Double? = nil
    var denoiseMode: RawDenoiseMode = .off
    var denoiseLuma: Double = 0.22
    var denoiseChroma: Double = 0.16
    var denoiseModel: String = "TreeNetDenoiseHeavy"

    // True RAW-develop controls. These are consumed by CIRAWFilter before SpektraFilm.
    var developExposureEV: Double = 0
    var developGlobalTone: Double = 1
    var developShadowBoost: Double = 1
    var developHighlightHeadroom: Double = 0
    var developCurvePoints: [ToneCurvePoint] = [.init(x: 0, y: 0), .init(x: 1, y: 1)]

    private enum CodingKeys: String, CodingKey {
        case whiteBalanceMode, temperature, tint, lensCorrection
        case temperatureOffsetMired, tintOffsetMired = "tintOffset"
        case denoiseMode, denoiseLuma, denoiseChroma, denoiseModel
        case developExposureEV, developGlobalTone, developShadowBoost
        case developHighlightHeadroom, developCurvePoints
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        whiteBalanceMode=try c.decodeIfPresent(RawWhiteBalanceMode.self,forKey:.whiteBalanceMode) ?? .asShot
        temperature=try c.decodeIfPresent(Double.self,forKey:.temperature) ?? 5500
        tint=try c.decodeIfPresent(Double.self,forKey:.tint) ?? 0
        lensCorrection=try c.decodeIfPresent(Bool.self,forKey:.lensCorrection) ?? false
        temperatureOffsetMired=try c.decodeIfPresent(Double.self,forKey:.temperatureOffsetMired)
        tintOffset=try c.decodeIfPresent(Double.self,forKey:.tintOffsetMired)
        denoiseMode=try c.decodeIfPresent(RawDenoiseMode.self,forKey:.denoiseMode) ?? .off
        denoiseLuma=min(1,max(0,try c.decodeIfPresent(Double.self,forKey:.denoiseLuma) ?? 0.22))
        denoiseChroma=min(1,max(0,try c.decodeIfPresent(Double.self,forKey:.denoiseChroma) ?? 0.16))
        denoiseModel=try c.decodeIfPresent(String.self,forKey:.denoiseModel) ?? "TreeNetDenoiseHeavy"
        developExposureEV=min(5,max(-5,try c.decodeIfPresent(Double.self,forKey:.developExposureEV) ?? 0))
        developGlobalTone=min(1,max(0,try c.decodeIfPresent(Double.self,forKey:.developGlobalTone) ?? 1))
        developShadowBoost=min(2,max(0,try c.decodeIfPresent(Double.self,forKey:.developShadowBoost) ?? 1))
        developHighlightHeadroom=min(2,max(0,try c.decodeIfPresent(Double.self,forKey:.developHighlightHeadroom) ?? 0))
        developCurvePoints=ToneCurveMath.normalize(try c.decodeIfPresent([ToneCurvePoint].self,forKey:.developCurvePoints) ?? [.init(x:0,y:0),.init(x:1,y:1)])
    }
    func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(whiteBalanceMode,forKey:.whiteBalanceMode);try c.encode(temperature,forKey:.temperature);try c.encode(tint,forKey:.tint);try c.encode(lensCorrection,forKey:.lensCorrection)
        try c.encodeIfPresent(temperatureOffsetMired,forKey:.temperatureOffsetMired);try c.encodeIfPresent(tintOffset,forKey:.tintOffsetMired)
        try c.encode(denoiseMode,forKey:.denoiseMode);try c.encode(denoiseLuma,forKey:.denoiseLuma);try c.encode(denoiseChroma,forKey:.denoiseChroma);try c.encode(denoiseModel,forKey:.denoiseModel)
        try c.encode(developExposureEV,forKey:.developExposureEV);try c.encode(developGlobalTone,forKey:.developGlobalTone);try c.encode(developShadowBoost,forKey:.developShadowBoost);try c.encode(developHighlightHeadroom,forKey:.developHighlightHeadroom);try c.encode(developCurvePoints,forKey:.developCurvePoints)
    }
}

struct ToneCurvePoint: Codable, Equatable, Hashable, Sendable, Identifiable {
    var x: Double
    var y: Double
    var id: String { String(format: "%.8f:%.8f", x, y) }
}

struct ToneSettings: Codable, Equatable, Hashable, Sendable {
    // Ranges follow Alcedo's scalar tone models. The Swift grade uses the sourced transfer
    // behavior documented in IMPLEMENTATION_SOURCES.md.
    var exposureEV: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var midtones: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var highlightRecovery: Double = 0
    var shadowRecovery: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var whitePoint: Double = 0
    var blackPoint: Double = 0
    // Dynamic, per-image automatic black/white level placement. The actual endpoints
    // are derived from the current developed image on every render; they are not copied
    // as fixed values between photographs.
    var autoContrast = false
    var curvePoints: [ToneCurvePoint] = [
        ToneCurvePoint(x: 0, y: 0),
        ToneCurvePoint(x: 1, y: 1)
    ]

    private enum CodingKeys: String, CodingKey {
        case exposureEV, brightness, contrast, midtones, highlights, shadows,
             highlightRecovery, shadowRecovery, whites, blacks, whitePoint, blackPoint,
             autoContrast, curvePoints
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        midtones = try c.decodeIfPresent(Double.self, forKey: .midtones) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        highlightRecovery = try c.decodeIfPresent(Double.self, forKey: .highlightRecovery) ?? 0
        shadowRecovery = try c.decodeIfPresent(Double.self, forKey: .shadowRecovery) ?? 0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        whitePoint = try c.decodeIfPresent(Double.self, forKey: .whitePoint) ?? 0
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        autoContrast = try c.decodeIfPresent(Bool.self, forKey: .autoContrast) ?? false
        curvePoints = try c.decodeIfPresent([ToneCurvePoint].self, forKey: .curvePoints) ?? [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)
        ]
    }
}

struct ColorDensitySettings: Codable, Equatable, Hashable, Sendable {
    // Active behavior follows ME_Desatch.dctl: 0 = identity, -1 = maximum deSatch density.
    // Property names stay stable so old projects/presets remain decodable.
    var master: Double = 0
    var red: Double = 0
    var yellow: Double = 0
    var green: Double = 0
    var cyan: Double = 0
    var blue: Double = 0
    var magenta: Double = 0

    // Legacy serialized field from the former Primera implementation.
    // It is intentionally ignored by ME deSatch but retained for backward decoding.
    var preserveLuma = true

    var isIdentity: Bool {
        [master, red, yellow, green, cyan, blue, magenta].allSatisfy {
            abs(min(0.0, max(-1.0, $0))) < 1e-12
        }
    }
}

enum GeometryAutoMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case auto = "Auto"
    case level = "Level"
    case vertical = "Vertical"
    case full = "Full"
    case guided = "Guided"
    var id: String { rawValue }
}

enum CropOverlayGuide: String, Codable, CaseIterable, Identifiable, Sendable {
    case thirds = "Rule of Thirds"
    case golden = "Golden Ratio"
    case diagonal = "Diagonals"
    case center = "Center"
    case safeAreas = "Safe Areas"
    case none = "None"
    var id: String { rawValue }
}

struct NormalizedCropRect: Codable, Equatable, Hashable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    mutating func clamp() {
        width = min(1, max(0.02, width))
        height = min(1, max(0.02, height))
        x = min(1 - width, max(0, x))
        y = min(1 - height, max(0, y))
    }
}

struct GeometryGuide: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Orientation: String, Codable, Sendable { case horizontal, vertical }
    var id = UUID()
    var orientation: Orientation
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
}

struct GeometrySettings: Codable, Equatable, Hashable, Sendable {
    var crop = NormalizedCropRect()
    var rotationDegrees: Double = 0
    var verticalPerspective: Double = 0
    var horizontalPerspective: Double = 0
    var aspect: Double = 0
    var scale: Double = 100
    var xOffset: Double = 0
    var yOffset: Double = 0
    var flipHorizontal = false
    var flipVertical = false
    var autoCrop = true
    var autoMode: GeometryAutoMode = .off
    var overlayGuide: CropOverlayGuide = .thirds
    var guides: [GeometryGuide] = []
    var lastAspectPresetID: String? = nil
}


enum LensCharacterPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case custom = "Custom"
    case spherical35 = "35mm Spherical"
    case standard50 = "50mm Standard"
    case portrait85 = "85mm Portrait"
    case wide28 = "28mm Wide"
    case anamorphic2x = "Anamorphic 2×"
    case petzval = "Petzval"
    case vintage58 = "Vintage 58mm"
    var id: String { rawValue }
}

enum LensCAChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case redBlue = "Red / Blue"
    case red = "Red Only"
    case blue = "Blue Only"
    var id: String { rawValue }
}

struct LensEffectsResolved: Sendable {
    var distortion = 0.0
    var chromaticAberration = 0.0
    var highlightChromaticAberration = 0.0
    var sphericalAberration = 0.0
    var petzvalSwirl = 0.0
    var edgeSoftness = 0.0
    var vignette = 0.0
    var lensShape = 1.0
    var blurThickness = 1.0
    var swirlRadius = 0.22
    var vignetteRadius = 0.40
    var vignetteFalloff = 1.6
    var centerX = 0.5
    var centerY = 0.5
    var caChannel: LensCAChannel = .redBlue
}

struct LensEffectsSettings: Codable, Equatable, Hashable, Sendable {
    var enabled = false
    var preset: LensCharacterPreset = .custom
    var distortion = 0.0
    var chromaticAberration = 0.0
    var highlightChromaticAberration = 0.0
    var sphericalAberration = 0.0
    var petzvalSwirl = 0.0
    var edgeSoftness = 0.0
    var vignette = 0.0
    var lensShape = 1.0
    var blurThickness = 1.0
    var swirlRadius = 0.22
    var vignetteRadius = 0.40
    var vignetteFalloff = 1.6
    var centerX = 0.5
    var centerY = 0.5
    var caChannel: LensCAChannel = .redBlue

    init() {}

    // Explicit defaults are necessary for saved projects written before this upgrade.
    private enum CodingKeys: String, CodingKey {
        case enabled, preset, distortion, chromaticAberration, highlightChromaticAberration,
             sphericalAberration, petzvalSwirl, edgeSoftness, vignette, lensShape,
             blurThickness, swirlRadius, vignetteRadius, vignetteFalloff, centerX, centerY, caChannel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preset = try c.decodeIfPresent(LensCharacterPreset.self, forKey: .preset) ?? .custom
        distortion = try c.decodeIfPresent(Double.self, forKey: .distortion) ?? 0
        chromaticAberration = try c.decodeIfPresent(Double.self, forKey: .chromaticAberration) ?? 0
        highlightChromaticAberration = try c.decodeIfPresent(Double.self, forKey: .highlightChromaticAberration) ?? 0
        sphericalAberration = try c.decodeIfPresent(Double.self, forKey: .sphericalAberration) ?? 0
        petzvalSwirl = try c.decodeIfPresent(Double.self, forKey: .petzvalSwirl) ?? 0
        edgeSoftness = try c.decodeIfPresent(Double.self, forKey: .edgeSoftness) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        lensShape = try c.decodeIfPresent(Double.self, forKey: .lensShape) ?? 1
        blurThickness = try c.decodeIfPresent(Double.self, forKey: .blurThickness) ?? 1
        swirlRadius = try c.decodeIfPresent(Double.self, forKey: .swirlRadius) ?? 0.22
        vignetteRadius = try c.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? 0.4
        vignetteFalloff = try c.decodeIfPresent(Double.self, forKey: .vignetteFalloff) ?? 1.6
        centerX = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5))
        centerY = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5))
        caChannel = try c.decodeIfPresent(LensCAChannel.self, forKey: .caChannel) ?? .redBlue
    }

    var resolved: LensEffectsResolved {
        if preset == .custom {
            return .init(distortion: distortion, chromaticAberration: chromaticAberration,
                         highlightChromaticAberration: highlightChromaticAberration,
                         sphericalAberration: sphericalAberration, petzvalSwirl: petzvalSwirl,
                         edgeSoftness: edgeSoftness, vignette: vignette, lensShape: lensShape,
                         blurThickness: blurThickness, swirlRadius: swirlRadius,
                         vignetteRadius: vignetteRadius, vignetteFalloff: vignetteFalloff,
                         caChannel: caChannel)
        }
        switch preset {
        case .spherical35:
            return .init(distortion: 0.016, chromaticAberration: 0.42, highlightChromaticAberration: 0.8, sphericalAberration: 0.26, petzvalSwirl: 0.10, edgeSoftness: 0.18, vignette: 0.24, lensShape: 1.0, blurThickness: 1.1, swirlRadius: 0.27, vignetteRadius: 0.46, vignetteFalloff: 1.8)
        case .standard50:
            return .init(distortion: 0.004, chromaticAberration: 0.30, highlightChromaticAberration: 0.5, sphericalAberration: 0.12, petzvalSwirl: 0.03, edgeSoftness: 0.09, vignette: 0.17, lensShape: 1.0, blurThickness: 0.9, swirlRadius: 0.34, vignetteRadius: 0.50, vignetteFalloff: 1.8)
        case .portrait85:
            return .init(distortion: -0.004, chromaticAberration: 0.28, highlightChromaticAberration: 0.55, sphericalAberration: 0.32, petzvalSwirl: 0.07, edgeSoftness: 0.20, vignette: 0.27, lensShape: 1.0, blurThickness: 1.2, swirlRadius: 0.38, vignetteRadius: 0.50, vignetteFalloff: 1.7)
        case .wide28:
            return .init(distortion: 0.043, chromaticAberration: 1.0, highlightChromaticAberration: 1.55, sphericalAberration: 0.08, petzvalSwirl: 0.04, edgeSoftness: 0.18, vignette: 0.35, lensShape: 1.0, blurThickness: 1.05, swirlRadius: 0.25, vignetteRadius: 0.36, vignetteFalloff: 1.4)
        case .anamorphic2x:
            return .init(distortion: 0.018, chromaticAberration: 0.85, highlightChromaticAberration: 1.6, sphericalAberration: 0.34, petzvalSwirl: 0.36, edgeSoftness: 0.38, vignette: 0.26, lensShape: 1.8, blurThickness: 1.6, swirlRadius: 0.16, vignetteRadius: 0.48, vignetteFalloff: 1.5)
        case .petzval:
            return .init(distortion: 0.008, chromaticAberration: 0.65, highlightChromaticAberration: 1.05, sphericalAberration: 0.65, petzvalSwirl: 0.95, edgeSoftness: 0.85, vignette: 0.42, lensShape: 1.05, blurThickness: 2.3, swirlRadius: 0.19, vignetteRadius: 0.32, vignetteFalloff: 1.4)
        case .vintage58:
            return .init(distortion: 0.009, chromaticAberration: 0.82, highlightChromaticAberration: 1.25, sphericalAberration: 0.60, petzvalSwirl: 0.32, edgeSoftness: 0.60, vignette: 0.37, lensShape: 1.0, blurThickness: 1.85, swirlRadius: 0.22, vignetteRadius: 0.40, vignetteFalloff: 1.5)
        case .custom:
            return .init()
        }
    }
    /// When changing a preset slider, materialize every resolved value first.
    /// Otherwise switching to Custom would silently reset the untouched sliders.
    var resolvedWithCenter: LensEffectsResolved {
        var value = resolved
        value.centerX = centerX
        value.centerY = centerY
        return value
    }

    mutating func bakePresetForEditing() {
        guard preset != .custom else { return }
        let r = resolved
        distortion = r.distortion
        chromaticAberration = r.chromaticAberration
        highlightChromaticAberration = r.highlightChromaticAberration
        sphericalAberration = r.sphericalAberration
        petzvalSwirl = r.petzvalSwirl
        edgeSoftness = r.edgeSoftness
        vignette = r.vignette
        lensShape = r.lensShape
        blurThickness = r.blurThickness
        swirlRadius = r.swirlRadius
        vignetteRadius = r.vignetteRadius
        vignetteFalloff = r.vignetteFalloff
        caChannel = r.caChannel
        preset = .custom
    }
    var isIdentity: Bool {
        let r = resolved
        return abs(r.distortion) < 1e-9 && r.chromaticAberration < 1e-9 &&
            r.highlightChromaticAberration < 1e-9 && r.sphericalAberration < 1e-9 &&
            r.petzvalSwirl < 1e-9 && r.edgeSoftness < 1e-9 && r.vignette < 1e-9
    }
}

struct RenderLook: Codable, Equatable, Hashable, Sendable {
    // v0.2 is intentionally Pro-only. Keep the serialized field for compatibility
    // with v0.1 project/preset documents and the native visibility model.
    var flavor: AppFlavor = .pro
    var values: [String: ParameterValue] = [:]
    var raw = RawSettings()
    // Optional preserves backwards decoding for projects/presets created before Tone existed.
    var tone: ToneSettings? = nil
    // Six-channel log-domain density is a host grade before SpektraFilm. Optional keeps old
    // project/preset documents backward compatible.
    var colorDensity: ColorDensitySettings? = nil
    // Geometry is also optional for backwards decoding. It is applied after the film/color render
    // so crop/straighten/perspective edits never change spectral/color behavior.
    var geometry: GeometrySettings? = nil
    var lensEffects: LensEffectsSettings? = nil
    // Stage 2: local grades own ordered mask stacks. Optional preserves backward decoding.
    var localGrades: [LocalGradeRecord]? = nil
    // Film-feed tonal shaping is independent of the scene host grade.
    // Optional preserves all previous project and preset JSON documents.
    var filmTone: ToneSettings? = nil

    static func defaults(catalog: BridgeCatalog = .shared) -> RenderLook {
        var look = RenderLook(flavor: .pro)
        look.tone = ToneSettings()
        look.colorDensity = ColorDensitySettings()
        look.geometry = GeometrySettings()
        look.lensEffects = LensEffectsSettings()
        look.localGrades = []
        look.filmTone = ToneSettings()
        for descriptor in catalog.parameters {
            look.values[descriptor.name] = descriptor.defaultValue
        }
        return look
    }

    mutating func normalizeForProOnly() {
        flavor = .pro
        if tone == nil { tone = ToneSettings() }
        if colorDensity == nil { colorDensity = ColorDensitySettings() }
        if geometry == nil { geometry = GeometrySettings() }
        if lensEffects == nil { lensEffects = LensEffectsSettings() }
        if localGrades == nil { localGrades = [] }
        if filmTone == nil { filmTone = ToneSettings() }
        for index in localGrades!.indices { localGrades![index].normalize() }
    }
}

struct PhotoMetadata: Codable, Equatable, Hashable, Sendable {
    var captureDate: Date? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var lensModel: String? = nil
    var iso: Int? = nil
    var aperture: Double? = nil
    var shutterSeconds: Double? = nil
    var focalLengthMM: Double? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    var cameraDisplay: String {
        [cameraMake, cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, part in
                if !values.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) { values.append(part) }
            }
            .joined(separator: " ")
    }
}

struct ProjectImageRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var sourcePath: String
    // Optional source fingerprint fields were added in v0.3. Existing projects decode
    // them as nil and can still be relinked by filename.
    var sourceFileSize: Int64? = nil
    var sourceModificationTime: TimeInterval? = nil
    var importedAt = Date()
    var captureDate: Date?
    var metadata: PhotoMetadata? = nil
    var rating: Int = 0
    var flag: ProjectFlag = .unflagged
    var selectedForExport = true
    var colorLabel: PhotoColorLabel? = nil
    var clientPicked: Bool = false
    var cullAnalysis: CullAnalysisRecord? = nil
    var keywords: [String]? = nil
    var note: String? = nil
    var look: RenderLook = .defaults()
    var cloudRelativePath: String? = nil
    var cloudPreviewRelativePath: String? = nil
    var logicalFolderPath: String? = nil

    var fileName: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
    var url: URL { URL(fileURLWithPath: sourcePath) }
}



extension ProjectImageRecord {
    private enum CodingKeys: String, CodingKey {
        case id, sourcePath, sourceFileSize, sourceModificationTime, importedAt, captureDate, metadata
        case rating, flag, selectedForExport, colorLabel, clientPicked, cullAnalysis, keywords, note, look
        case cloudRelativePath, cloudPreviewRelativePath, logicalFolderPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        sourceFileSize = try c.decodeIfPresent(Int64.self, forKey: .sourceFileSize)
        sourceModificationTime = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceModificationTime)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        captureDate = try c.decodeIfPresent(Date.self, forKey: .captureDate)
        metadata = try c.decodeIfPresent(PhotoMetadata.self, forKey: .metadata)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        flag = try c.decodeIfPresent(ProjectFlag.self, forKey: .flag) ?? .unflagged
        selectedForExport = try c.decodeIfPresent(Bool.self, forKey: .selectedForExport) ?? true
        colorLabel = try c.decodeIfPresent(PhotoColorLabel.self, forKey: .colorLabel)
        clientPicked = try c.decodeIfPresent(Bool.self, forKey: .clientPicked) ?? false
        cullAnalysis = try c.decodeIfPresent(CullAnalysisRecord.self, forKey: .cullAnalysis)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        look = try c.decodeIfPresent(RenderLook.self, forKey: .look) ?? .defaults()
        cloudRelativePath = try c.decodeIfPresent(String.self, forKey: .cloudRelativePath)
        cloudPreviewRelativePath = try c.decodeIfPresent(String.self, forKey: .cloudPreviewRelativePath)
        logicalFolderPath = try c.decodeIfPresent(String.self, forKey: .logicalFolderPath)
    }
}

struct PersonGroup: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var imageIDs: Set<UUID> = []
    var coverImageID: UUID? = nil
    var detectedFaceCount: Int = 0
    var createdAt = Date()
}

struct PhotoAlbum: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var imageIDs: Set<UUID> = []
    var createdAt = Date()
}

struct SmartCollection: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var minimumRating: Int = 0
    var flag: ProjectFlag? = nil
    var colorLabel: PhotoColorLabel? = nil
    var cullRecommendation: CullRecommendation? = nil
    var searchText: String = ""
    var createdAt = Date()
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case tiff = "TIFF"
    var id: String { rawValue }
    var fileExtension: String {
        switch self { case .jpeg: "jpg"; case .heic: "heic"; case .tiff: "tif" }
    }
}

enum ExportResizeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "Full Size"
    case longEdge = "Long Edge"
    case width = "Width"
    case height = "Height"
    case fitBox = "Fit Inside"
    case cropToFill = "Crop to Fill"
    var id: String { rawValue }
}

enum ExportColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sRGB = "sRGB · Web / Phone"
    case matchRenderer = "Match Renderer"
    var id: String { rawValue }
}

struct ExportSettings: Codable, Equatable, Hashable, Sendable {
    var format: ExportFormat = .jpeg
    var colorMode: ExportColorMode = .sRGB
    var jpegQuality: Double = 0.92
    var tiff16Bit = true
    var preserveMetadata = true
    var stripGPS = false
    var resizeMode: ExportResizeMode = .none
    var resizeWidth = 2048
    var resizeHeight = 2048
    var resizeLongEdge = 2048
    var dontEnlarge = true
    var filenameTemplate = "{name}_spektrafilm"
    var sequenceStart = 1
    var destinationPath: String = ""

    private enum CodingKeys: String, CodingKey {
        case format, colorMode, jpegQuality, tiff16Bit, preserveMetadata, stripGPS
        case resizeMode, resizeWidth, resizeHeight, resizeLongEdge, dontEnlarge
        case filenameTemplate, sequenceStart, destinationPath
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .jpeg
        colorMode = try c.decodeIfPresent(ExportColorMode.self, forKey: .colorMode) ?? .sRGB
        jpegQuality = min(1, max(0.1, try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.92))
        tiff16Bit = try c.decodeIfPresent(Bool.self, forKey: .tiff16Bit) ?? true
        preserveMetadata = try c.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? true
        stripGPS = try c.decodeIfPresent(Bool.self, forKey: .stripGPS) ?? false
        resizeMode = try c.decodeIfPresent(ExportResizeMode.self, forKey: .resizeMode) ?? .none
        resizeWidth = try c.decodeIfPresent(Int.self, forKey: .resizeWidth) ?? 2048
        resizeHeight = try c.decodeIfPresent(Int.self, forKey: .resizeHeight) ?? 2048
        resizeLongEdge = try c.decodeIfPresent(Int.self, forKey: .resizeLongEdge) ?? 2048
        dontEnlarge = try c.decodeIfPresent(Bool.self, forKey: .dontEnlarge) ?? true
        filenameTemplate = try c.decodeIfPresent(String.self, forKey: .filenameTemplate) ?? "{name}_spektrafilm"
        sequenceStart = try c.decodeIfPresent(Int.self, forKey: .sequenceStart) ?? 1
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(colorMode, forKey: .colorMode)
        try c.encode(jpegQuality, forKey: .jpegQuality)
        try c.encode(tiff16Bit, forKey: .tiff16Bit)
        try c.encode(preserveMetadata, forKey: .preserveMetadata)
        try c.encode(stripGPS, forKey: .stripGPS)
        try c.encode(resizeMode, forKey: .resizeMode)
        try c.encode(resizeWidth, forKey: .resizeWidth)
        try c.encode(resizeHeight, forKey: .resizeHeight)
        try c.encode(resizeLongEdge, forKey: .resizeLongEdge)
        try c.encode(dontEnlarge, forKey: .dontEnlarge)
        try c.encode(filenameTemplate, forKey: .filenameTemplate)
        try c.encode(sequenceStart, forKey: .sequenceStart)
        try c.encode(destinationPath, forKey: .destinationPath)
    }
}

enum PreviewCacheMemoryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic"
    case conservative = "Conservative"
    case aggressive = "Aggressive"
    var id: String { rawValue }
}

enum SkinCheckMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case overlay = "Overlay"
    case scope = "Scope"
    case both = "Both"
    var id: String { rawValue }
}

enum ClippingPreviewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullGamut = "Full Gamut"
    case anyRGB = "Any RGB Channel"
    case luminance = "Luminance Only"
    case saturation = "Saturation Only"
    var id: String { rawValue }
}

struct AppPreferences: Codable, Equatable, Hashable, Sendable {
    static let editProxyLongEdge = 1080
    // Editing uses one persistent 1080px linear working file. Live and idle editing stay at
    // the same resolution; only explicit Full Resolution Preview and Export reopen the original.
    var workingFileLongEdge = Self.editProxyLongEdge
    var previewLongEdge = Self.editProxyLongEdge
    var interactiveLongEdge = Self.editProxyLongEdge
    var fullResolutionPreview = false
    var bypassImportTransform = false
    var cacheMemoryMode: PreviewCacheMemoryMode = .automatic
    var localDiskCacheGB = 15
    var autosaveEnabled = true
    var autoAdvanceRatings = false
    var paperBackground = true
    var scopeEnabled = true
    var scopeMode: ScopeMode = .waveform
    var scopeTargetFPS = 20
    var autoAnalyzeCull = true
    var writeXMPAutomatically = false

    var clippingEnabled = false
    var clippingPreviewMode: ClippingPreviewMode = .fullGamut
    // "Risk" thresholds remain SpektraFilmFast's early display warning. The hard thresholds
    // below follow darktable's current final-output clipping defaults more closely.
    var exposureHighlightRiskThreshold = 0.95
    var exposureShadowRiskThreshold = 0.02
    var clippingHighlightThreshold = 0.9999
    // darktable's 8-bit sRGB black reference: -12.69 EV relative to white.
    var clippingShadowThreshold = 0.00015133150634020836
    var skinCheckEnabled = false
    var skinCheckMode: SkinCheckMode = .both
    var skinToleranceDegrees = 12.0
    var skinOverlayOpacity = 0.30

    var shortcutPrevious = "left"
    var shortcutNext = "right"
    var shortcutPick = "p"
    var shortcutReject = "x"
    var shortcutUnflag = "u"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case workingFileLongEdge, previewLongEdge, interactiveLongEdge, fullResolutionPreview, bypassImportTransform
        case cacheMemoryMode, localDiskCacheGB, autosaveEnabled, autoAdvanceRatings, paperBackground
        case scopeEnabled, scopeMode, scopeTargetFPS, autoAnalyzeCull, writeXMPAutomatically
        case clippingEnabled, clippingPreviewMode, exposureHighlightRiskThreshold, exposureShadowRiskThreshold
        case clippingHighlightThreshold, clippingShadowThreshold
        case skinCheckEnabled, skinCheckMode, skinToleranceDegrees, skinOverlayOpacity
        case shortcutPrevious, shortcutNext, shortcutPick, shortcutReject, shortcutUnflag
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // v0.5.2 fixes the edit workfile at 1080 px. Decode older values for compatibility,
        // but intentionally do not restore them into the active editing policy.
        _ = try c.decodeIfPresent(Int.self, forKey: .workingFileLongEdge)
        _ = try c.decodeIfPresent(Int.self, forKey: .previewLongEdge)
        _ = try c.decodeIfPresent(Int.self, forKey: .interactiveLongEdge)
        workingFileLongEdge = Self.editProxyLongEdge
        previewLongEdge = Self.editProxyLongEdge
        interactiveLongEdge = Self.editProxyLongEdge
        fullResolutionPreview = try c.decodeIfPresent(Bool.self, forKey: .fullResolutionPreview) ?? false
        bypassImportTransform = try c.decodeIfPresent(Bool.self, forKey: .bypassImportTransform) ?? false
        cacheMemoryMode = try c.decodeIfPresent(PreviewCacheMemoryMode.self, forKey: .cacheMemoryMode) ?? .automatic
        localDiskCacheGB = min(100, max(2, try c.decodeIfPresent(Int.self, forKey: .localDiskCacheGB) ?? 15))
        autosaveEnabled = try c.decodeIfPresent(Bool.self, forKey: .autosaveEnabled) ?? true
        autoAdvanceRatings = try c.decodeIfPresent(Bool.self, forKey: .autoAdvanceRatings) ?? false
        paperBackground = try c.decodeIfPresent(Bool.self, forKey: .paperBackground) ?? true
        scopeEnabled = try c.decodeIfPresent(Bool.self, forKey: .scopeEnabled) ?? true
        scopeMode = try c.decodeIfPresent(ScopeMode.self, forKey: .scopeMode) ?? .waveform
        scopeTargetFPS = min(30, max(5, try c.decodeIfPresent(Int.self, forKey: .scopeTargetFPS) ?? 20))
        autoAnalyzeCull = try c.decodeIfPresent(Bool.self, forKey: .autoAnalyzeCull) ?? true
        writeXMPAutomatically = try c.decodeIfPresent(Bool.self, forKey: .writeXMPAutomatically) ?? false

        clippingEnabled = try c.decodeIfPresent(Bool.self, forKey: .clippingEnabled) ?? false
        clippingPreviewMode = try c.decodeIfPresent(ClippingPreviewMode.self, forKey: .clippingPreviewMode) ?? .fullGamut
        exposureHighlightRiskThreshold = try c.decodeIfPresent(Double.self, forKey: .exposureHighlightRiskThreshold) ?? 0.95
        exposureShadowRiskThreshold = try c.decodeIfPresent(Double.self, forKey: .exposureShadowRiskThreshold) ?? 0.02

        let decodedHighlightClip = try c.decodeIfPresent(Double.self, forKey: .clippingHighlightThreshold) ?? 0.9999
        clippingHighlightThreshold = abs(decodedHighlightClip - 0.998) < 1.0e-12
            ? 0.9999
            : decodedHighlightClip

        let decodedShadowClip = try c.decodeIfPresent(Double.self, forKey: .clippingShadowThreshold) ?? 0.00015133150634020836
        clippingShadowThreshold = abs(decodedShadowClip - 0.002) < 1.0e-12
            ? 0.00015133150634020836
            : decodedShadowClip
        skinCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .skinCheckEnabled) ?? false
        skinCheckMode = try c.decodeIfPresent(SkinCheckMode.self, forKey: .skinCheckMode) ?? .both
        skinToleranceDegrees = try c.decodeIfPresent(Double.self, forKey: .skinToleranceDegrees) ?? 12.0
        skinOverlayOpacity = try c.decodeIfPresent(Double.self, forKey: .skinOverlayOpacity) ?? 0.30

        shortcutPrevious = try c.decodeIfPresent(String.self, forKey: .shortcutPrevious) ?? "left"
        shortcutNext = try c.decodeIfPresent(String.self, forKey: .shortcutNext) ?? "right"
        shortcutPick = try c.decodeIfPresent(String.self, forKey: .shortcutPick) ?? "p"
        shortcutReject = try c.decodeIfPresent(String.self, forKey: .shortcutReject) ?? "x"
        shortcutUnflag = try c.decodeIfPresent(String.self, forKey: .shortcutUnflag) ?? "u"
    }
}

struct SpektraProjectDocument: Codable, Equatable, Sendable {
    var formatVersion = 6
    var name: String = "Untitled Project"
    var workspaceMode: WorkspaceMode = .project
    var images: [ProjectImageRecord] = []
    var selectedImageID: UUID?
    var sortMode: ProjectSortMode = .importDate
    var filterRating: Int = 0
    var filterFlag: ProjectFlag? = nil
    var albums: [PhotoAlbum] = []
    var peopleGroups: [PersonGroup] = []
    var smartCollections: [SmartCollection] = []
    var exportSettings = ExportSettings()
    var preferences = AppPreferences()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, workspaceMode, images, selectedImageID, sortMode
        case filterRating, filterFlag, albums, peopleGroups, smartCollections, exportSettings, preferences
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Project"
        workspaceMode = try c.decodeIfPresent(WorkspaceMode.self, forKey: .workspaceMode) ?? .project
        images = try c.decodeIfPresent([ProjectImageRecord].self, forKey: .images) ?? []
        guard Set(images.map(\.id)).count == images.count else {
            throw DecodingError.dataCorruptedError(forKey: .images, in: c, debugDescription: "Duplicate photo identities in project")
        }
        selectedImageID = try c.decodeIfPresent(UUID.self, forKey: .selectedImageID)
        sortMode = try c.decodeIfPresent(ProjectSortMode.self, forKey: .sortMode) ?? .importDate
        filterRating = try c.decodeIfPresent(Int.self, forKey: .filterRating) ?? 0
        filterFlag = try c.decodeIfPresent(ProjectFlag.self, forKey: .filterFlag)
        albums = try c.decodeIfPresent([PhotoAlbum].self, forKey: .albums) ?? []
        peopleGroups = try c.decodeIfPresent([PersonGroup].self, forKey: .peopleGroups) ?? []
        smartCollections = try c.decodeIfPresent([SmartCollection].self, forKey: .smartCollections) ?? []
        exportSettings = try c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? ExportSettings()
        preferences = try c.decodeIfPresent(AppPreferences.self, forKey: .preferences) ?? AppPreferences()
    }

    mutating func migrateForV2() {
        let migrateSceneToneToRaw = formatVersion < 7
        formatVersion = max(formatVersion, 7)
        let validIDs = Set(images.map(\.id))
        for index in images.indices {
            images[index].look.normalizeForProOnly()
            if migrateSceneToneToRaw {
                let oldTone = images[index].look.tone ?? ToneSettings()
                images[index].look.raw.developExposureEV = min(5, max(-5, oldTone.exposureEV))
                let oldCurve = ToneCurveMath.normalize(oldTone.curvePoints)
                let identity = oldCurve.count == 2 && abs(oldCurve[0].x) < 1e-9 && abs(oldCurve[0].y) < 1e-9 && abs(oldCurve[1].x - 1) < 1e-9 && abs(oldCurve[1].y - 1) < 1e-9
                if !identity { images[index].look.raw.developCurvePoints = oldCurve }
                images[index].look.tone = ToneSettings()
            }
        }
        for index in albums.indices {
            albums[index].imageIDs.formIntersection(validIDs)
        }
        for index in peopleGroups.indices {
            peopleGroups[index].imageIDs.formIntersection(validIDs)
            if let cover = peopleGroups[index].coverImageID, !validIDs.contains(cover) {
                peopleGroups[index].coverImageID = peopleGroups[index].imageIDs.first
            }
        }
        peopleGroups.removeAll { $0.imageIDs.isEmpty }
        if let selectedImageID, !validIDs.contains(selectedImageID) {
            self.selectedImageID = images.first?.id
        }
    }
}

struct SpektraPreset: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var category: String = "Custom"
    var createdAt = Date()
    var look: RenderLook
}

struct RenderDiagnosticsView: Equatable, Sendable {
    var cpuSetupMs = 0.0
    var sourceCopyMs = 0.0
    var commandBufferMs = 0.0
    var outputCopyMs = 0.0
    var passCount: UInt32 = 0
    var uploadBytes: UInt64 = 0
    var totalMs: Double { cpuSetupMs + sourceCopyMs + commandBufferMs + outputCopyMs }
}

struct StudioAnalysisMetrics: Equatable, Sendable {
    // Risk percentages include the hard-clipped pixels. Hard percentages are the subset
    // that has crossed the near-white / near-black clipping threshold.
    var highlightPercent = 0.0
    var shadowPercent = 0.0
    var hardHighlightPercent = 0.0
    var hardShadowPercent = 0.0
    var skinCandidatePercent = 0.0
    var skinMeanDeviationDegrees = 0.0
    var skinWithinTolerancePercent = 0.0
    var skinMagentaPercent = 0.0
    var skinGreenPercent = 0.0
    // Confidence-weighted final-render skin centroid in the vectorscope's normalized Cb/Cr plane.
    // These are diagnostic values only; they are never serialized into the image pipeline.
    var skinMeanCbNormalized = 0.0
    var skinMeanCrNormalized = 0.0
    var skinMeanRadius = 0.0
    var skinMeasurementConfidencePercent = 0.0
    var sampledPixels = 0
}
