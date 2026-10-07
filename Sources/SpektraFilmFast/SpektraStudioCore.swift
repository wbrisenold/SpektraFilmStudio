import Foundation
import CSpektraStudioCore

enum SpektraStudioCore {
    static let abiVersion = Int(sf_core_abi_version())
    static let capabilities = UInt64(sf_core_capabilities())
    static var isAvailable: Bool { abiVersion == 3 }

    static func jsonString(
        initialCapacity: Int = 64 * 1024,
        _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32
    ) -> String? {
        var buffer = [UInt8](repeating: 0, count: initialCapacity)
        var rc = buffer.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        if rc > 0 {
            buffer = [UInt8](repeating: 0, count: Int(rc))
            rc = buffer.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        }
        guard rc == 0, let zero = buffer.firstIndex(of: 0) else { return nil }
        return String(bytes: buffer[..<zero], encoding: .utf8)
    }

    static var lightCraftControlSchemaJSON: String? {
        jsonString { sf_core_lc_controls_json($0, $1) }
    }

    static var defaultLightCraftDevelopJSON: String? {
        jsonString { sf_core_lc_default_settings_json($0, $1) }
    }

    static var spektraFeatureManifestJSON: String? {
        jsonString { sf_core_spektra_feature_manifest_json($0, $1) }
    }

    static func setLightCraftControl(settingsJSON: String, id: String, value: Double) -> String? {
        settingsJSON.withCString { settingsPtr in
            id.withCString { idPtr in
                jsonString { sf_core_lc_set_control_json(settingsPtr, idPtr, value, $0, $1) }
            }
        }
    }
}

enum SpektraFeatureCompatibility {
    enum Backend: String { case spektraNative, lightCraft, hybrid }

    struct Feature {
        let id: String
        let backend: Backend
        let preserveExistingUIUntilParity: Bool
    }

    static let required: [Feature] = [
        .init(id: "falseColor", backend: .spektraNative, preserveExistingUIUntilParity: true),
        .init(id: "clippingIndicator", backend: .spektraNative, preserveExistingUIUntilParity: true),
        .init(id: "saturationScope", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "skinAnalysis", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "skinVectorscope", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "autoSkinWB", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "presets", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "curvePresets", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "semanticMasks", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "export", backend: .hybrid, preserveExistingUIUntilParity: true),
    ]
}
