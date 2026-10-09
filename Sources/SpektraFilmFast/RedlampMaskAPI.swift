// Adapted from pdcgomes/redlamp at 0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd.
// SPDX-License-Identifier: MPL-2.0. See Resources/Redlamp-MPL-2.0.txt.
import Foundation
import CryptoKit
public struct ImagePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BrushStroke: Codable, Sendable, Hashable {
    public var points: [ImagePoint]
    /// Pen pressure at each point, 0...1. Empty when the input had none (full pressure).
    public var pressures: [Double]
    /// The brush radius, as a fraction of the image *height* (like radial radii).
    public var size: Double
    /// 0...100: the share of the radius that fades out.
    public var feather: Double
    /// 0...100: how much each dab adds, so overlapping dabs build up.
    public var flow: Double
    /// 0...100: the most coverage the stroke can reach.
    public var density: Double
    /// Removes coverage instead of adding it.
    public var erase: Bool
    /// Keeps each dab to colours like the one under its centre (Lightroom's Auto Mask).
    public var autoMask: Bool

    public init(
        points: [ImagePoint],
        pressures: [Double] = [],
        size: Double,
        feather: Double = 50,
        flow: Double = 100,
        density: Double = 100,
        erase: Bool = false,
        autoMask: Bool = false,
    ) {
        self.points = points
        self.pressures = pressures
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
        self.erase = erase
        self.autoMask = autoMask
    }

    public func pressure(at index: Int) -> Double {
        index < pressures.count ? min(max(pressures[index], 0), 1) : 1
    }
}

public enum PersonPart: String, Codable, Sendable, Hashable, CaseIterable {
    case entirePerson, faceSkin, bodySkin, eyebrows, eyeSclera, iris, lips, teeth, hair, facialHair, clothes

    public var name: String {
        switch self {
        case .entirePerson: "Entire Person"
        case .faceSkin: "Face Skin"
        case .bodySkin: "Body Skin"
        case .eyebrows: "Eyebrows"
        case .eyeSclera: "Eye Sclera"
        case .iris: "Iris and Pupil"
        case .lips: "Lips"
        case .teeth: "Teeth"
        case .hair: "Hair"
        case .facialHair: "Facial Hair"
        case .clothes: "Clothes"
        }
    }

    /// Whether `name` is plural ("No eyebrows were found").
    public var isPlural: Bool {
        [.eyebrows, .iris, .lips, .teeth, .clothes].contains(self)
    }
}

/// Lightroom's Landscape classes (Sky is a mask kind of its own). Each pixel belongs to one.
public enum LandscapeClass: String, Codable, Sendable, Hashable, CaseIterable {
    case water, vegetation, mountains, architecture, naturalGround, artificialGround
    /// Lightroom Classic 15's.
    case snow

    public var name: String {
        switch self {
        case .water: "Water"
        case .vegetation: "Vegetation"
        case .mountains: "Mountains"
        case .architecture: "Architecture"
        case .naturalGround: "Natural Ground"
        case .artificialGround: "Artificial Ground"
        case .snow: "Snow"
        }
    }

    /// Whether `name` is plural ("No mountains were found").
    public var isPlural: Bool {
        self == .mountains
    }
}

/// What an AI mask is computed for. Masks are computed from the photo without any edit, so
/// they don't move when the edit changes.
/// A person People finds in the open photo, for the People picker: Vision's person instance,
/// where they are, and their face. A face part's AI mask is numbered by its face
/// (`faceInstance`), a whole person's or a SAM 3 part's by the person.
public struct PersonFound: Sendable, Hashable, Identifiable {
    /// Their person instance; nil when Vision can't tell people apart (none separated, or four or
    /// more), so People covers everyone as one.
    public var instance: Int?
    /// The instance of their face's parts (Face Skin, Lips, Teeth...), when a face is found in them.
    public var faceInstance: Int?
    /// Their bounds, and their face's, in the oriented frame (0...1 from the top left).
    public var box: ImageRect
    public var face: ImageRect?

    public var id: Int {
        instance ?? -1
    }

    public init(instance: Int?, faceInstance: Int? = nil, box: ImageRect, face: ImageRect? = nil) {
        self.instance = instance
        self.faceInstance = faceInstance
        self.box = box
        self.face = face
    }
}

public struct MaskRequest: Sendable, Hashable {
    public var kind: MaskKind
    /// For People: the part of each person.
    public var part: PersonPart
    /// For Objects: points the user clicked (the first selects, more refine).
    public var prompts: [ImagePoint]
    /// For Objects: points to leave out (Option-click).
    public var excluded: [ImagePoint]
    /// One mask for everyone found, rather than one per person.
    public var combined: Bool
    /// For Landscape: which class.
    public var landscape: LandscapeClass
    /// For Objects: a box around the object (dragged, or a thing found by name), which bounds it
    /// as the prompts point at it.
    public var box: ImageRect?
    /// For People: only these people (`PersonFound.instance`); nil for everyone.
    public var people: [Int]?

    public init(
        kind: MaskKind, part: PersonPart = .entirePerson, prompts: [ImagePoint] = [], excluded: [ImagePoint] = [],
        combined: Bool = false, landscape: LandscapeClass = .vegetation, box: ImageRect? = nil, people: [Int]? = nil,
    ) {
        self.kind = kind
        self.part = part
        self.prompts = prompts
        self.excluded = excluded
        self.combined = combined
        self.landscape = landscape
        self.box = box
        self.people = people
    }

}
public enum MaskComputationError: Error, Equatable, CustomStringConvertible {
    /// The kind of mask needs a model this device doesn't have yet.
    case unsupported(MaskKind)
    /// The model found nothing to select (no subject, no people, no sky).
    case nothingFound(MaskKind)
    /// The model found none of a People part or a Landscape class (`name`, plural or not).
    case partNotFound(name: String, plural: Bool)
    /// Without SAM 3, hair comes only from a hair matte the camera embedded (iPhone portraits).
    case needsHairMatte
    /// Body skin, facial hair and clothes come only from SAM 3 (an evaluation model).
    case needsSAM3(PersonPart)

    public static func notFound(_ part: PersonPart) -> MaskComputationError {
        .partNotFound(name: part.name, plural: part.isPlural)
    }

    public static func notFound(_ landscape: LandscapeClass) -> MaskComputationError {
        .partNotFound(name: landscape.name, plural: landscape.isPlural)
    }

    public var description: String {
        switch self {
        case let .unsupported(kind): "\(kind.name) masks aren't available on this device yet."
        case .nothingFound(.people): "No people were found in this photo."
        case .nothingFound(.objects): "Nothing was found to select there."
        case let .nothingFound(kind): "No \(kind.name.lowercased()) was found in this photo."
        case let .partNotFound(name, plural): "No \(name.lowercased()) \(plural ? "were" : "was") found in this photo."
        case .needsHairMatte: "Hair masks need a photo with its own hair matte, such as an iPhone portrait."
        case let .needsSAM3(part): "\(part.name) masks need the SAM 3 evaluation model."
        }
    }
}

public enum MaskKind: String, CaseIterable, Codable, Sendable, Hashable {
    case subject, sky, background, objects, people, landscape
    case brush, linear, radial
    case colorRange, luminanceRange, depthRange
    /// Another mask's coverage, reused as a component.
    case existingMask

    /// The types in the Create New Mask menu.
    public static let creatable: [MaskKind] = allCases.filter { $0 != .existingMask }

    /// Computed by a model from the photo, rather than drawn.
    public var isAI: Bool {
        switch self {
        case .subject, .sky, .background, .objects, .people, .landscape, .depthRange: true
        default: false
        }
    }

    public var name: String {
        switch self {
        case .subject: "Subject"
        case .sky: "Sky"
        case .background: "Background"
        case .objects: "Objects"
        case .people: "People"
        case .landscape: "Landscape"
        case .brush: "Brush"
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        case .colorRange: "Color Range"
        case .luminanceRange: "Luminance Range"
        case .depthRange: "Depth Range"
        case .existingMask: "Existing Mask"
        }
    }

    public var symbol: String {
        switch self {
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        case .background: "rectangle.dashed"
        case .objects: "cube"
        case .people: "person.2"
        case .landscape: "mountain.2"
        case .brush: "paintbrush.pointed"
        case .linear: "square.split.1x2"
        case .radial: "circle.circle"
        case .colorRange: "eyedropper.halffull"
        case .luminanceRange: "sun.max"
        case .depthRange: "square.3.layers.3d"
        case .existingMask: "square.on.square"
        }
    }

    /// `nil` once the engine renders the mask type.
    public var plannedPhase: String? {
        switch self {
        case .linear, .radial, .brush, .colorRange, .luminanceRange, .existingMask: nil
        case .subject, .sky, .background, .people, .depthRange, .objects, .landscape: nil
        }
    }

    public var isAvailable: Bool {
        plannedPhase == nil
    }
}

import Foundation

public struct PixelSize: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    public var longEdge: Int {
        max(width, height)
    }

    public var megapixels: Double {
        Double(width * height) / 1_000_000
    }

    public var aspectRatio: Double {
        height == 0 ? 1 : Double(width) / Double(height)
    }

    /// The largest size with this aspect ratio that fits inside `bounds`, never larger
    /// than `self`.
    public func fitted(within bounds: PixelSize) -> PixelSize {
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(Double(bounds.width) / Double(width), Double(bounds.height) / Double(height), 1)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded())),
        )
    }
}

import CoreGraphics
import Foundation


/// A rectangle in normalized image coordinates, after orientation: (0, 0) is the top-left
/// corner of the photo as displayed and (1, 1) the bottom-right.
public struct ImageRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = ImageRect(x: 0, y: 0, width: 1, height: 1)
}


public struct MaskBitmap: Sendable, Hashable {
    public var png: Data
    public var width: Int
    public var height: Int
    public init(png: Data, width: Int, height: Int) { self.png = png; self.width = width; self.height = height }
}
enum HalfPrecision {
    static func float(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = Int((half >> 10) & 31)
        let mantissa = UInt32(half & 1023)
        if exponent == 0 { return (half & 0x8000 == 0 ? 1 : -1) * Float(mantissa) * pow(2, -24) }
        if exponent == 31 { return Float(bitPattern: sign | 0x7f800000 | (mantissa << 13)) }
        return Float(bitPattern: sign | (UInt32(exponent + 112) << 23) | (mantissa << 13))
    }
}
