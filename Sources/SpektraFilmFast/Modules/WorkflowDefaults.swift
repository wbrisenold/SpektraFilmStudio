// Module registration and auto-apply workflow defaults

import Foundation

extension PixelpipeRegistry {
    func registerBuiltinModules() {
        // RAW preparation
        register(RawPrepareModule())
        register(WhiteBalanceModule())
        register(HighlightReconstructionModule())
        register(HotPixelModule())
        register(RawDenoiseModule())
        register(RawCAModule())
        register(DemosaicModule())
        register(ExposureModule())
        register(ColorCalibrationModule())

        // Tone mappers (only one should be enabled at a time)
        register(FilmicRGBModule())
        register(AgXModule())
        register(SigmoidModule())

        // More modules to be added...
    }

    /// Apply auto-apply pixel workflow defaults (Darktable style)
    func applyWorkflowDefaults(_ workflow: WorkflowPreset) {
        // Disable all first. Go through setEnabled so mutation happens under the
        // registry lock rather than on loop-local copies of the existentials.
        for module in getAllModules() {
            setEnabled(module.name, false)
        }

        switch workflow {
        case .sceneReferredFilmic:
            enableSceneReferredFilmic()
        case .sceneReferredAgX:
            enableSceneReferredAgX()
        case .sceneReferredSigmoid:
            enableSceneReferredSigmoid()
        case .displayReferredLegacy:
            enableDisplayReferredLegacy()
        case .none:
            enableNone()
        }
    }

    private func enableSceneReferredFilmic() {
        let modules = [
            "rawprepare", "whitebalance", "highlights", "cacorrect", "hotpixels",
            "rawdenoise", "demosaic", "denoiseprofile", "lens", "exposure",
            "colorin", "colorcalibration", "filmicrgb",
        ]
        for name in modules { setEnabled(name, true) }
    }

    private func enableSceneReferredAgX() {
        let modules = [
            "rawprepare", "whitebalance", "highlights", "cacorrect", "hotpixels",
            "rawdenoise", "demosaic", "denoiseprofile", "lens", "exposure",
            "colorin", "colorcalibration", "agx",
        ]
        for name in modules { setEnabled(name, true) }
    }

    private func enableSceneReferredSigmoid() {
        let modules = [
            "rawprepare", "whitebalance", "highlights", "cacorrect", "hotpixels",
            "rawdenoise", "demosaic", "denoiseprofile", "lens", "exposure",
            "colorin", "colorcalibration", "sigmoid",
        ]
        for name in modules { setEnabled(name, true) }
    }

    private func enableDisplayReferredLegacy() {
        let modules = [
            "rawprepare", "whitebalance", "basecurve",
        ]
        for name in modules { setEnabled(name, true) }
    }

    private func enableNone() {
        let modules = [
            "rawprepare", "whitebalance",
        ]
        for name in modules { setEnabled(name, true) }
    }
}

enum WorkflowPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    var id: String { rawValue }
    case sceneReferredFilmic = "scene-referred (filmic)"
    case sceneReferredAgX = "scene-referred (AgX)"
    case sceneReferredSigmoid = "scene-referred (sigmoid)"
    case displayReferredLegacy = "display-referred (legacy)"
    case none = "none"

    var description: String {
        switch self {
        case .sceneReferredFilmic:
            return "Scene-referred workflow with Filmic RGB tone mapping (recommended)"
        case .sceneReferredAgX:
            return "Scene-referred workflow with AgX tone mapping"
        case .sceneReferredSigmoid:
            return "Scene-referred workflow with Sigmoid tone mapping"
        case .displayReferredLegacy:
            return "Legacy display-referred workflow with Base Curve"
        case .none:
            return "Minimal workflow - only raw preparation"
        }
    }
}
