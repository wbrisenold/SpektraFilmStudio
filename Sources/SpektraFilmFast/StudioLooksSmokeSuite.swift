import Foundation
import CryptoKit

// Runs on a real Mac/Metal device as part of the pre-existing LUT smoke launch.
// This is a color-only identity test, NOT a ΔE certification of baked film assets.
enum StudioLooksSmokeSuite {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFS-LooksSmoke-\(UUID().uuidString)", isDirectory: true)
        let pack = root.appendingPathComponent("identity", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = Data(capacity: 65 * 65 * 65 * 16)
        for b in 0..<65 { for g in 0..<65 { for r in 0..<65 {
            var pixel = SIMD4<Float>(Float(r)/64, Float(g)/64, Float(b)/64, 1)
            withUnsafeBytes(of: &pixel) { data.append(contentsOf: $0) }
        } } }
        try data.write(to: pack.appendingPathComponent("cube.bin"), options: .atomic)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = """
        {"version":1,"id":"identity","name":"Identity","category":"Tests",
        "source":{"filmStock":"identity","printStock":"none",
                  "coreHash":"smoke-test-core-v1","bakeSchema":1},
        "input":{"space":"linear-rec2020","shaper":"domain-linear",
                 "domainMin":[0,0,0],"domainMax":[1,1,1]},
        "output":{"space":"linear-rec2020"},
        "cube":{"file":"cube.bin","format":"rgba32f-le","size":65,"sha256":"\(hash)"},
        "defaults":{"strength":1,"exposure":0,"contrast":0}}
        """
        try manifest.write(to: pack.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
        let manifestDecoded = try StudioLooksPack.manifest(in: pack)
        guard manifestDecoded.cubeURL?.lastPathComponent == "cube.bin" else {
            throw GPULiveError.unavailable("Looks manifest selection failed")
        }
        let input = PixelBufferF32(width: 2, height: 2, pixels: [
            0.0, 0.0, 0.0, 1, 0.4, 0.2, 0.7, 1,
            0.9, 0.7, 0.1, 1, 1.0, 1.0, 1.0, 1
        ])
        let reference = input.pixels
        let output = try await StudioImportedLUTOffline.shared.render(input,
                            file: pack.appendingPathComponent("cube.bin"))
        guard reference.count == output.pixels.count,
              zip(reference, output.pixels).allSatisfy({ abs($0.0 - $0.1) < 0.015 }) else {
            throw GPULiveError.unavailable("LOOKS_IDENTITY_FAIL: pack->shader altered color")
        }
        let afterFirst = await StudioImportedLUTOffline.shared.gpuCacheCounts()
        let second = try await StudioImportedLUTOffline.shared.render(input,
                           file: pack.appendingPathComponent("cube.bin"))
        let afterSecond = await StudioImportedLUTOffline.shared.gpuCacheCounts()
        guard afterSecond.uploads == afterFirst.uploads,
              afterSecond.hits > afterFirst.hits,
              second.pixels == output.pixels else {
            throw GPULiveError.unavailable("LOOKS_RESIDENCY_FAIL: repeated frame reloaded LUT")
        }
        print("LOOKS_GPU_SMOKE_PASS: 65^3 binary identity, Rec.2020 color, resident LUT reuse")
    }
}
