// Minimal WorkflowPreset enum for compatibility.
// The Darktable v5.0 pipeline modules have been removed.
// Rendering uses the native ImageDecoder path directly.

import Foundation

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
            return "Scene-referred workflow with Filmic RGB tone mapping"
        case .sceneReferredAgX:
            return "Scene-referred workflow with AgX tone mapping"
        case .sceneReferredSigmoid:
            return "Scene-referred workflow with Sigmoid tone mapping"
        case .displayReferredLegacy:
            return "Legacy display-referred workflow"
        case .none:
            return "Minimal workflow"
        }
    }
}

// MARK: - PixelpipeRegistry stub (compatibility only)
// Thread-safe stub since the real registry was removed with the Darktable pipeline.

final class PixelpipeRegistry: @unchecked Sendable {
    static let shared = PixelpipeRegistry()
    private let lock = NSLock()
    private init() {}

    func register(_: any Any) {}
    func getEnabledModules() -> [any Any] { [] }
    func getAllModules() -> [any Any] { [] }
    func module(named _: String) -> (any Any)? { nil }
    func setEnabled(_: String, _: Bool) {}

    func applyWorkflowDefaults(_: WorkflowPreset) {}
    func registerBuiltinModules() {}
    func enableDefaultSceneReferred() {}
    func registerDefaults() {}
}
