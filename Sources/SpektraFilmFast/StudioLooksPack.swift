import CoreGraphics
import CryptoKit
import Foundation
import Metal

// A Look is immutable. It never asks NativeRenderer to bake while editing.
// The pack carries a scene-linear Rec.2020 input contract and a LINEAR Rec.2020
// output. MetalPreviewCanvas performs the final color-managed monitor conversion.
enum StudioLooksSettings {
    static let modeKey = StudioSpectralLUT.setting
    static let folderKey = "SpektraFilmStudio.looks.folder.v1"
    static let selectedIDKey = "SpektraFilmStudio.looks.selected.v1"
    static var isSelected: Bool { UserDefaults.standard.string(forKey: modeKey) == "looks" }

    private static let manifestCache = ManifestCache()
    private final class ManifestCache: @unchecked Sendable {
        let lock = NSLock()
        var key = ""
        var stamp: Date?
        var item: StudioLooksPack.Manifest?
        func get(root: String, id: String) -> StudioLooksPack.Manifest? {
            guard !root.isEmpty, !id.isEmpty,
                id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(id, isDirectory: true)
            let url = folder.appendingPathComponent("manifest.json")
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lock.lock(); defer { lock.unlock() }
            let proposedKey = folder.standardizedFileURL.path
            if proposedKey == key && modified == stamp { return item }
            let parsed = try? StudioLooksPack.manifest(in: folder)
            key = proposedKey; stamp = modified
            item = parsed?.id == id ? parsed : nil
            return item
        }
    }
    static var selectedPack: StudioLooksPack.Manifest? {
        let defaults = UserDefaults.standard
        return manifestCache.get(
            root: defaults.string(forKey: folderKey) ?? "",
            id: defaults.string(forKey: selectedIDKey) ?? "")
    }
    static func selectedPack(for look: RenderLook) -> StudioLooksPack.Manifest? {
        let defaults = UserDefaults.standard
        return manifestCache.get(
            root: defaults.string(forKey: folderKey) ?? "",
            id: look.studioLookID ?? "")
    }
    static func scalar(_ look: RenderLook, _ key: String, default initial: Double) -> Float {
        let value = look.values["looks." + key]?.scalarValue ?? initial
        return Float(value.isFinite ? value : initial)
    }
}

enum StudioLooksPack {
    struct Source: Codable {
        let filmStock: String
        let printStock: String
        let scannerProfile: String?
        let coreHash: String
        let bakeSchema: Int
    }
    struct Input: Codable {
        let space: String
        let shaper: String
        let domainMin: [Float]
        let domainMax: [Float]
    }
    struct Output: Codable { let space: String }
    struct CubeInfo: Codable {
        let file: String
        let format: String
        let size: Int
        let sha256: String
    }
    struct Defaults: Codable {
        let strength: Float
        let exposure: Float
        let contrast: Float
    }
    struct Grain: Codable {
        let response: [Float]
        let defaultSize: Float
        let defaultAmount: Float
    }
    struct Halation: Codable {
        let tint: [Float]
        let defaultRadius: Float
        let defaultAmount: Float
    }
    struct Manifest: Codable, Identifiable {
        let version: Int
        let id: String
        let name: String
        let category: String
        let thumbnail: String?
        let source: Source
        let input: Input
        let output: Output
        let cube: CubeInfo
        let defaults: Defaults
        let grain: Grain?
        let halation: Halation?
        // Used by the UI only; URLs are always reconstructed from validated pack roots.
        var folder: URL? = nil

        enum CodingKeys: String, CodingKey {
            case version, id, name, category, thumbnail, source, input, output, cube, defaults, grain, halation
        }
        var cubeURL: URL? {
            guard let folder, cube.file == "cube.bin" else { return nil }
            return folder.appendingPathComponent("cube.bin", isDirectory: false)
        }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return "Look pack: " + message }
            return "Invalid Look pack"
        }
    }

    static func discover(in root: URL) -> [Manifest] {
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            else { return nil }
            return try? manifest(in: url)
        }
    }

    static func manifest(in folder: URL) throws -> Manifest {
        let manifestFile = folder.appendingPathComponent("manifest.json")
        let props = try manifestFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard props.isRegularFile == true, props.isSymbolicLink != true,
            (props.fileSize ?? 0) <= 65536
        else {
            throw Failure.invalid("Missing or oversized manifest")
        }
        let bytes = try Data(contentsOf: manifestFile)
        var manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard manifest.version == 1, manifest.id.count <= 96, !manifest.id.isEmpty,
            manifest.name.count <= 180,
            manifest.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
            manifest.cube.file == "cube.bin", manifest.cube.size == 65,
            ["rgba32f-le", "rgba16f-le"].contains(manifest.cube.format),
            manifest.input.space == "linear-rec2020",
            ["signed-log2-v1", "domain-linear"].contains(manifest.input.shaper),
            manifest.output.space == "linear-rec2020",
            manifest.input.domainMin.count == 3, manifest.input.domainMax.count == 3,
            manifest.source.coreHash.count >= 7, manifest.source.bakeSchema > 0,
            manifest.cube.sha256.count == 64
        else {
            throw Failure.invalid("Looks mode needs a 65³ linear Rec.2020 pack with an explicit shaper and SHA-256")
        }
        for i in 0..<3 {
            guard manifest.input.domainMin[i].isFinite, manifest.input.domainMax[i].isFinite,
                manifest.input.domainMax[i] > manifest.input.domainMin[i]
            else {
                throw Failure.invalid("Invalid shaper-domain bounds")
            }
        }
        if manifest.input.shaper == "signed-log2-v1"
            && (manifest.input.domainMin != [0, 0, 0] || manifest.input.domainMax != [1, 1, 1])
        {
            throw Failure.invalid("Signed-log look requires encoded domain 0...1")
        }
        manifest.folder = folder
        return manifest
    }

    // Float16 is unavailable on this deployment target; decode IEEE half bits manually.
    private static func halfToFloat(_ bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Int(bits & 0x3FF)
        switch exponent {
        case 0:
            guard mantissa != 0 else { return bits == 0x8000 ? -0 : 0 }
            return sign * Float(mantissa) * 0x1p-24
        case 0x1F:
            return mantissa == 0 ? sign * .infinity : .nan
        default:
            let scale = Float(bitPattern: UInt32(exponent - 15 + 127) << 23)
            return sign * Float(1024 + mantissa) * 0x1p-23 * scale
        }
    }

    // 65^3 * float4; validates exact length and checksum BEFORE allocating the GPU LUT.
    static func loadPackedCube(url: URL) throws -> StudioImportedLUT.Cube {
        guard url.lastPathComponent == "cube.bin" else { throw Failure.invalid("Expected cube.bin") }
        let folder = url.deletingLastPathComponent()
        let manifest = try manifest(in: folder)
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let bytesPerChannel = manifest.cube.format == "rgba32f-le" ? 4 : 2
        let expected = 65 * 65 * 65 * 4 * bytesPerChannel
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
            properties.fileSize == expected
        else { throw Failure.invalid("LUT byte length doesn't match 65³ RGBA format") }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard checksum == manifest.cube.sha256.lowercased() else {
            throw Failure.invalid("Look asset checksum mismatch")
        }
        var values = [SIMD4<Float>]()
        values.reserveCapacity(65 * 65 * 65)
        bytes.withUnsafeBytes { raw in
            for pixel in 0..<(65 * 65 * 65) {
                let offset = pixel * 4 * bytesPerChannel
                func component(_ c: Int) -> Float {
                    let p = offset + c * bytesPerChannel
                    let base = raw.baseAddress!.advanced(by: p)
                    if bytesPerChannel == 4 {
                        return Float(
                            bitPattern: UInt32(littleEndian: base.assumingMemoryBound(to: UInt32.self).pointee))
                    }
                    let bits = UInt16(littleEndian: base.assumingMemoryBound(to: UInt16.self).pointee)
                    return halfToFloat(bits)
                }
                values.append(SIMD4(component(0), component(1), component(2), component(3)))
            }
        }
        guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else {
            throw Failure.invalid("Non-finite LUT output sample")
        }
        let shaper: StudioImportedLUT.Shaper = manifest.input.shaper == "signed-log2-v1" ? .signedLog2 : .domainLinear
        let contract = StudioImportedLUT.Contract(
            version: 1, input: .linearRec2020,
            output: .linearRec2020, shaper: shaper, role: .fullFilmPrint)
        return StudioImportedLUT.Cube(
            size: 65, values: values,
            domainMin: SIMD3(manifest.input.domainMin[0], manifest.input.domainMin[1], manifest.input.domainMin[2]),
            domainMax: SIMD3(manifest.input.domainMax[0], manifest.input.domainMax[1], manifest.input.domainMax[2]),
            contract: contract, assumedSRGB: false)
    }
}
