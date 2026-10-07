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
                jsonString {
                    sf_core_lc_set_control_json(settingsPtr, idPtr, value, $0, $1)
                }
            }
        }
    }

    static func selectSubject(rgba: [UInt8], width: Int, height: Int) -> [UInt8]? {
        guard isAvailable, rgba.count == width * height * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let rc = rgba.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                sf_core_pc_select_subject_rgba8(
                    input.baseAddress, UInt32(width), UInt32(height), output.baseAddress
                )
            }
        }
        return rc == 0 ? out : nil
    }

    static func quickSelect(
        rgba: [UInt8], width: Int, height: Int,
        points: [(Float, Float)], brushSize: Float
    ) -> [UInt8]? {
        guard isAvailable, !points.isEmpty, rgba.count == width * height * 4 else { return nil }
        var packed: [Float] = []
        packed.reserveCapacity(points.count * 2)
        for p in points { packed.append(p.0); packed.append(p.1) }
        var out = [UInt8](repeating: 0, count: width * height)

        let rc = rgba.withUnsafeBufferPointer { input in
            packed.withUnsafeBufferPointer { pts in
                out.withUnsafeMutableBufferPointer { output in
                    sf_core_pc_quick_select_rgba8(
                        input.baseAddress, UInt32(width), UInt32(height),
                        pts.baseAddress, UInt32(points.count), brushSize, output.baseAddress
                    )
                }
            }
        }
        return rc == 0 ? out : nil
    }

    static func magicWand(
        rgba: [UInt8], width: Int, height: Int,
        x: Int, y: Int, tolerance: Float
    ) -> [UInt8]? {
        guard isAvailable, rgba.count == width * height * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let rc = rgba.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                sf_core_pc_magic_wand_rgba8(
                    input.baseAddress, UInt32(width), UInt32(height),
                    Int32(x), Int32(y), tolerance, output.baseAddress
                )
            }
        }
        return rc == 0 ? out : nil
    }

    static func feather(
        _ alpha: [UInt8], width: Int, height: Int, radius: Float
    ) -> [UInt8]? {
        guard isAvailable, alpha.count == width * height else { return nil }
        var out = [UInt8](repeating: 0, count: alpha.count)
        let rc = alpha.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                sf_core_pc_feather_mask_u8(
                    input.baseAddress, UInt32(width), UInt32(height),
                    radius, output.baseAddress
                )
            }
        }
        return rc == 0 ? out : nil
    }
}

enum SpektraFeatureCompatibility {
    enum Backend: String { case spektraNative, lightCraft, photoCraft, hybrid }

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
        .init(id: "nativeFilmStockExposureEV", backend: .spektraNative, preserveExistingUIUntilParity: true),
        .init(id: "filmExposureShape", backend: .spektraNative, preserveExistingUIUntilParity: true),
        .init(id: "semanticMasks", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "createSocial", backend: .hybrid, preserveExistingUIUntilParity: true),
        .init(id: "export", backend: .hybrid, preserveExistingUIUntilParity: true),
    ]
}
