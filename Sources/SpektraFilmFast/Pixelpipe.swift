// Scene-referred pixelpipe module system for SpektraFilmStudio
// Mirrors Darktable's v5.0 RAW module order

import CoreImage
import Foundation
import Metal
import simd

// MARK: - Pixelpipe Errors

enum PipelineError: Error, Sendable {
    case wrongBufferType
    case unsupportedModule
    case invalidConfiguration(String)
}

/// Processing color space for a module
enum PixelpipeColorSpace: Sendable {
    case raw  // IOP_CS_RAW - single-channel Bayer
    case rgb  // IOP_CS_RGB - linear scene-referred RGB
    case lab  // IOP_CS_LAB - CIE Lab
    case displayRGB  // non-linear display-referred RGB
}

/// Module position in pixelpipe (lower = earlier)
struct ModuleOrder: Comparable, Sendable {
    let value: Double
    let name: String

    static func < (lhs: ModuleOrder, rhs: ModuleOrder) -> Bool {
        lhs.value < rhs.value
    }
}

/// Common protocol for pipeline buffers (RAW mosaic or RGB)
protocol PipelineBuffer: Sendable {
    var width: Int { get }
    var height: Int { get }
    var pixels: [Float] { get set }
    var channels: Int { get }
}

/// Base protocol for all pixelpipe modules
///
/// Buffers cross module boundaries as `any PipelineBuffer` so modules stay
/// type-erased and this protocol remains existential-safe. Concrete buffer
/// access is via `asRawMosaic` / `asPixelBuffer` (see `extension PipelineBuffer`).
protocol PixelpipeModule: Sendable {
    var name: String { get }
    var order: ModuleOrder { get }
    var inputColorSpace: PixelpipeColorSpace { get }
    var outputColorSpace: PixelpipeColorSpace { get }
    var isEnabled: Bool { get set }
    var blendingOpacity: Float { get set }

    /// Process the image through this module
    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer

    /// Check if module can operate on given image
    func canProcess(_ input: any PipelineBuffer) -> Bool
}

/// Context passed through pixelpipe
struct PixelpipeContext: Sendable {
    let rawSettings: RawSettings
    let look: RenderLook
    let metadata: RawSpeedMetadata?
    let ciContext: CIContext
    let metalDevice: MTLDevice?
    let metalQueue: MTLCommandQueue?

    // Intermediate buffers for modules that need them
    var intermediateBuffers: [String: PixelBufferF32] = [:]

    // Module-specific state
    var moduleStates: [String: ModuleState] = [:]
}

/// Opaque module state
struct ModuleState: Sendable {
    private let data: [String: String]
    init(_ data: [String: String] = [:]) { self.data = data }
}

// MARK: - Module Registry

/// Central registry of all pixelpipe modules in order
final class PixelpipeRegistry: @unchecked Sendable {
    private var modules: [any PixelpipeModule] = []
    private let lock = NSLock()

    static let shared = PixelpipeRegistry()
    private init() {}

    func register(_ module: any PixelpipeModule) {
        lock.lock()
        defer { lock.unlock() }
        modules.append(module)
        modules.sort { $0.order < $1.order }
    }

    func getEnabledModules() -> [any PixelpipeModule] {
        lock.lock()
        defer { lock.unlock() }
        return modules.filter { $0.isEnabled }
    }

    func getAllModules() -> [any PixelpipeModule] {
        lock.lock()
        defer { lock.unlock() }
        return modules
    }

    func module(named name: String) -> (any PixelpipeModule)? {
        lock.lock()
        defer { lock.unlock() }
        return modules.first { $0.name == name }
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // Conforming modules are reference types, so this mutates the registered
        // instance in place rather than a temporary copy.
        if var module = modules.first(where: { $0.name == name }) {
            module.isEnabled = enabled
        }
    }
}

// MARK: - v5.0 RAW Module Order (Darktable)

extension ModuleOrder {
    // RAW preparation (must be first)
    static let rawPrepare = ModuleOrder(value: 1.0, name: "rawprepare")
    static let invert = ModuleOrder(value: 2.0, name: "invert")
    static let whiteBalance = ModuleOrder(value: 3.0, name: "whitebalance")
    static let highlightRecon = ModuleOrder(value: 4.0, name: "highlights")
    static let rawCA = ModuleOrder(value: 5.0, name: "cacorrect")
    static let hotPixels = ModuleOrder(value: 6.0, name: "hotpixels")
    static let rawDenoise = ModuleOrder(value: 7.0, name: "rawdenoise")
    static let demosaic = ModuleOrder(value: 8.0, name: "demosaic")
    static let profiledDenoise = ModuleOrder(value: 9.0, name: "denoiseprofile")
    static let surfaceBlur = ModuleOrder(value: 10.0, name: "surfaceblur")

    // Geometric (rotate/scale before lens)
    static let rotatePixels = ModuleOrder(value: 11.0, name: "rotatepixels")
    static let scalePixels = ModuleOrder(value: 12.0, name: "scalepixels")
    static let lensCorrection = ModuleOrder(value: 13.0, name: "lens")
    static let rgbCA = ModuleOrder(value: 13.5, name: "cacorrectrgb")
    static let hazeRemoval = ModuleOrder(value: 14.0, name: "hazeremoval")
    static let perspective = ModuleOrder(value: 15.0, name: "perspective")
    static let orientation = ModuleOrder(value: 16.0, name: "orientation")
    static let crop = ModuleOrder(value: 17.0, name: "crop")
    static let graduatedND = ModuleOrder(value: 18.0, name: "graduatednd")

    // Color calibration (before tone mapping)
    static let unbreakProfile = ModuleOrder(value: 19.0, name: "unbreakinputprofile")
    static let inputProfile = ModuleOrder(value: 20.0, name: "colorin")
    static let colorCalibration = ModuleOrder(value: 21.0, name: "colorcalibration")
    static let censorize = ModuleOrder(value: 22.0, name: "censorize")
    static let negadoctor = ModuleOrder(value: 23.0, name: "negadoctor")

    // Tone mapping (scene-referred)
    static let exposure = ModuleOrder(value: 24.0, name: "exposure")
    static let toneEqualizer = ModuleOrder(value: 25.0, name: "toneequal")
    static let contrastEqualizer = ModuleOrder(value: 26.0, name: "equalizer")
    static let lowpass = ModuleOrder(value: 27.0, name: "lowpass")
    static let highpass = ModuleOrder(value: 28.0, name: "highpass")
    static let sharpen = ModuleOrder(value: 29.0, name: "sharpen")

    // Creative color (scene-referred)
    static let colorBalance = ModuleOrder(value: 30.0, name: "colorbalance")
    static let colorBalanceRGB = ModuleOrder(value: 31.0, name: "colorbalancergb")
    static let rgbCurve = ModuleOrder(value: 32.0, name: "rgbcurve")
    static let rgbLevels = ModuleOrder(value: 33.0, name: "rgblevels")

    // Tone mappers (transition to display-referred)
    static let baseCurve = ModuleOrder(value: 44.0, name: "basecurve")
    static let filmic = ModuleOrder(value: 45.0, name: "filmic")
    static let sigmoid = ModuleOrder(value: 45.3, name: "sigmoid")
    static let agx = ModuleOrder(value: 45.5, name: "agx")
    static let filmicRGB = ModuleOrder(value: 46.0, name: "filmicrgb")

    // Post tone mapping (display-referred)
    static let lut3D = ModuleOrder(value: 36.0, name: "lut3d")
    static let colorCorrection = ModuleOrder(value: 55.0, name: "colorcorrection")
    static let colorContrast = ModuleOrder(value: 56.0, name: "colorcontrast")
    static let velvia = ModuleOrder(value: 57.0, name: "velvia")
    static let colorZones = ModuleOrder(value: 60.0, name: "colorzones")
    static let bloom = ModuleOrder(value: 61.0, name: "bloom")
    static let colorize = ModuleOrder(value: 62.0, name: "colorize")
    static let lowlight = ModuleOrder(value: 63.0, name: "lowlight")
    static let monochrome = ModuleOrder(value: 64.0, name: "monochrome")
    static let grain = ModuleOrder(value: 65.0, name: "grain")
    static let soften = ModuleOrder(value: 66.0, name: "soften")
    static let splitToning = ModuleOrder(value: 67.0, name: "splittoning")
    static let vignette = ModuleOrder(value: 68.0, name: "vignette")
    static let colorReconstruct = ModuleOrder(value: 69.0, name: "colorreconstruct")

    // Output
    static let outputProfile = ModuleOrder(value: 70.0, name: "colorout")
    static let dither = ModuleOrder(value: 71.0, name: "dither")
    static let borders = ModuleOrder(value: 72.0, name: "borders")
    static let watermark = ModuleOrder(value: 73.0, name: "watermark")
    static let gamma = ModuleOrder(value: 74.0, name: "gamma")
}

// MARK: - Pixelpipe Execution Engine

/// Executes the pixelpipe in order
actor PixelpipeEngine {
    private let registry = PixelpipeRegistry.shared

    private func ensureModulesRegistered() {
        if registry.getAllModules().isEmpty {
            registry.registerBuiltinModules()
        }
        let rawModules: Set<String> = [
            "rawprepare", "whitebalance", "highlights", "cacorrect",
            "hotpixels", "rawdenoise", "demosaic",
        ]
        for module in registry.getAllModules() {
            registry.setEnabled(module.name, rawModules.contains(module.name))
        }
    }

    func execute(
        rawMosaic: RawMosaicF32,
        rawSettings: RawSettings,
        look: RenderLook,
        metadata: RawSpeedMetadata?,
        ciContext: CIContext,
        metalDevice: MTLDevice? = nil,
        metalQueue: MTLCommandQueue? = nil
    ) async throws -> PixelBufferF32 {

        ensureModulesRegistered()

        let enabledModules = registry.getEnabledModules()

        guard let metadata = metadata else {
            throw PipelineError.invalidConfiguration("Missing metadata for RAW processing")
        }

        var currentRaw = rawMosaic

        var currentRGB: PixelBufferF32? = nil
        var hasDemosaiced = false

        var context = PixelpipeContext(
            rawSettings: rawSettings,
            look: look,
            metadata: metadata,
            ciContext: ciContext,
            metalDevice: metalDevice,
            metalQueue: metalQueue
        )

        for module in enabledModules {
            let isRawModule = module.inputColorSpace == .raw

            if hasDemosaiced {
                // Every ModuleOrder below demosaic is RAW and every one above it is RGB,
                // so the other combination is a misconfigured pipeline. Failing loudly
                // beats skipping the module and returning an ungraded image.
                guard !isRawModule else {
                    throw PipelineError.invalidConfiguration(
                        "RAW module '\(module.name)' is ordered after demosaic and would never run")
                }
                guard let rgb = currentRGB else {
                    throw PipelineError.invalidConfiguration(
                        "Demosaic produced no RGB buffer for '\(module.name)'")
                }
                guard module.canProcess(rgb) else { continue }

                let processed = try module.process(rgb, context: &context)
                currentRGB = blend(rgb, processed, opacity: module.blendingOpacity)
            } else {
                guard isRawModule else {
                    throw PipelineError.invalidConfiguration(
                        "Module '\(module.name)' needs an RGB buffer but no demosaic has run yet")
                }
                guard module.canProcess(currentRaw) else { continue }

                let processed = try module.process(currentRaw, context: &context)
                currentRaw = blend(currentRaw, processed, opacity: module.blendingOpacity)

                // Demosaic is the RAW->RGB transition point
                if let rgb = processed.asPixelBuffer {
                    hasDemosaiced = true
                    currentRGB = rgb
                }
            }
        }

        guard let currentRGB else {
            throw PipelineError.invalidConfiguration("No demosaic module produced an RGB buffer")
        }
        return currentRGB
    }

    func enableDefaultSceneReferred() {
        // Enable default scene-referred modules (Darktable defaults)
        let defaults: [String] = [
            "rawprepare", "whitebalance", "highlights", "cacorrect", "hotpixels",
            "rawdenoise", "demosaic", "denoiseprofile", "lens", "exposure",
            "colorin", "colorcalibration", "filmicrgb",
        ]
        for name in defaults {
            registry.setEnabled(name, true)
        }
    }

    func registerDefaults() {
        // Register all available modules (stubs for now)
        // Real implementations will register themselves
    }
}

// MARK: - Module Blending

/// Interpolation for `blendingOpacity`. Returns `base` when the overlay is a
/// different buffer type (e.g. demosaic crossing RAW->RGB) or is not the same
/// shape, so a type transition is never silently averaged away.
private func blend(_ base: RawMosaicF32, _ overlay: any PipelineBuffer, opacity: Float) -> RawMosaicF32 {
    guard let over = overlay.asRawMosaic else { return base }
    if opacity <= 0 { return base }
    if opacity >= 1 { return over }
    guard base.width == over.width, base.height == over.height,
        base.pixels.count == over.pixels.count
    else { return base }
    var result = base
    for i in result.pixels.indices {
        result.pixels[i] += (over.pixels[i] - base.pixels[i]) * opacity
    }
    return result
}

private func blend(_ base: PixelBufferF32, _ overlay: any PipelineBuffer, opacity: Float) -> PixelBufferF32 {
    guard let over = overlay.asPixelBuffer else { return base }
    if opacity <= 0 { return base }
    if opacity >= 1 { return over }
    guard base.width == over.width, base.height == over.height,
        base.pixels.count == over.pixels.count
    else { return base }
    var result = base
    for i in result.pixels.indices {
        result.pixels[i] += (over.pixels[i] - base.pixels[i]) * opacity
    }
    return result
}
