import CoreGraphics
import CoreImage
import Foundation
@preconcurrency import Metal

// App-level Mac/Metal smoke test. Invoked with --lut-smoke-test; no photos
// and no user LUT assets required. It tests actual GPU output, GPU cache
// reuse and missing/invalid LUT refusal (not merely a settings selection).
enum StudioLUTSmokeSuite {
    private enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case let .failed(message) = self { return message }
            return "Unknown LUT smoke test failure"
        }
    }

    static func run() async throws {
        try await StudioLooksSmokeSuite.run()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFS-LUT-SMOKE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let csv = folder.appendingPathComponent("LUT_Catalog.csv")
        let srgb = folder.appendingPathComponent("portra_endura.cube")
        let linear = folder.appendingPathComponent("rec2020.cube")
        try makeCube(path: srgb, size: 2, sceneLinear: false)
        try makeCube(path: linear, size: 17, sceneLinear: true)
        let metadata = """
            lut_path,film_profile,print_profile,stage,status
            portra_endura.cube,kodak_portra_400,kodak_endura,full_chain,completed
            rec2020.cube,Fuji 400,Crystal Archive,full_chain,completed
            """
        try metadata.write(to: csv, atomically: true, encoding: .utf8)
        let items = try StudioImportedLUT.discover(folder: folder)
        guard items.count == 2,
            items.contains(where: { $0.name.contains("kodak portra 400") && $0.name.contains("kodak endura") }),
            items.contains(where: { $0.name.contains("Fuji 400") })
        else {
            throw Failure.failed("CSV LUT catalog labels do not match indexed cubes")
        }
        let source = PixelBufferF32(
            width: 2, height: 1,
            pixels: [
                0.18, 0.18, 0.18, 1.0, 0.41, 0.12, 0.23, 1.0,
            ])
        // Fresh instance: the prepended Looks smoke shares `.shared` and its
        // cumulative upload counters would break the absolute count assertions.
        let offline = StudioImportedLUTOffline()
        let first = try await offline.render(source, file: srgb)
        let counts1 = await offline.gpuCacheCounts()
        let second = try await offline.render(source, file: srgb)
        let counts2 = await offline.gpuCacheCounts()
        guard counts1.uploads == 1, counts2.uploads == 1, counts2.hits >= 1,
            first.pixels.count == source.pixels.count,
            first.pixels == second.pixels,
            // Corrected shader converts linear Rec.2020 input to encoded
            // sRGB before the LUT, so identity mid-gray ≈0.46 (not 0.18).
            first.pixels[0].isFinite, first.pixels[0] > 0.40, first.pixels[0] < 0.52,
            first.pixels[3] == 1
        else {
            throw Failure.failed("sRGB LUT Metal output/reuse/alpha validation failed")
        }
        // Test the whole path: GPU LUT -> private float32 texture -> the SAME
        // CIImage import / letterbox / display conversion used by MTKView.
        // A 2-pixel LUT assertion alone never catches an all-gray viewer.
        try await verifyActualDisplayPath(file: srgb)
        let linearResult = try await offline.render(source, file: linear)
        let counts3 = await offline.gpuCacheCounts()
        guard counts3.uploads == 2,
            linearResult.pixels[0].isFinite,
            abs(linearResult.pixels[0] - first.pixels[0]) < 0.07
        else {
            throw Failure.failed("scene-linear Rec.2020 shaper GPU output invalid")
        }
        try "LUT_3D_SIZE 17\n0 0 0\n".write(
            to: folder.appendingPathComponent("invalid.cube"), atomically: true, encoding: .utf8)
        do {
            _ = try await offline.render(source, file: folder.appendingPathComponent("invalid.cube"))
            throw Failure.failed("Malformed LUT was incorrectly accepted")
        } catch is StudioImportedLUT.Failure {
            // Expected: never silently replace a selected invalid LUT with native film.
        }
        // Separate smoke for the internally GENERATED LUT. Unlike imported
        // LUTs this exercises a spectral bake, then confirms host edits reuse it.
        let key = StudioSpectralLUT.setting
        let oldPreference = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldPreference {
                UserDefaults.standard.set(oldPreference, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set("33", forKey: key)
        var look = RenderLook.defaults()
        look.values["fastDIR"] = .bool(true)
        look.values["autoExposure"] = .bool(false)
        look.values["grainEnabled"] = .bool(false)
        look.values["halationEnabled"] = .bool(false)
        look.values["cameraDiffusionEnabled"] = .bool(false)
        look.values["printDiffusionEnabled"] = .bool(false)
        look.values["scannerEnabled"] = .bool(false)
        let pipeline = GPULiveFramePipeline()
        if let blocker = try await pipeline.lutBlockReason(look: look) {
            throw Failure.failed("Generated-LUT smoke remains blocked: \(blocker)")
        }
        guard try await pipeline.prewarmLUT(look: look) != nil else {
            throw Failure.failed("First spectral LUT prewarm returned nil")
        }
        let output1 = try await pipeline.settledCachedFilmLUT(source, look: look)
        var hostOnly = look
        hostOnly.raw.developExposureEV = 0.6
        hostOnly.tone?.exposureEV = 0.4
        guard StudioSpectralLUT.bakeSignature(for: look) == StudioSpectralLUT.bakeSignature(for: hostOnly) else {
            throw Failure.failed("RAW/exposure edit changed the film LUT bake signature")
        }
        let prepared2 = try await pipeline.prewarmLUT(look: hostOnly)
        guard case .inMemory? = prepared2 else {
            throw Failure.failed("Second spectral LUT prepare was not a cache hit")
        }
        let output2 = try await pipeline.settledCachedFilmLUT(source, look: hostOnly)
        guard let output1, let output2, output1.pixels == output2.pixels,
            output1.pixels.allSatisfy(\.isFinite)
        else {
            throw Failure.failed("Settled generated LUT not reused across host edit")
        }
        print(
            "LUT_SMOKE_PASS: CSV catalog, imported sRGB/Rec.2020 Metal, GPU reuse, bad-file rejection, generated LUT no-rebake across RAW/exposure"
        )
    }

    // A full-picture GPU test: shader computation alone is not sufficient.
    // This is the actual BGRA8/sRGB CI display conversion used in MTKView.
    private static func verifyActualDisplayPath(file: URL) async throws {
        guard let device = StudioGPUDevice.shared else {
            throw Failure.failed("Cannot run real Metal presentation smoke without GPU")
        }
        let gpu = try GPULiveDevice(device: device)
        let lut = try StudioImportedLUTMetal(gpu: gpu)
        let width = 96, height = 64
        var pixels = [Float]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Float(x) / Float(width - 1)
                let v = Float(y) / Float(height - 1)
                let light: Float = (x < width / 2 ? 0.12 : 0.63) + 0.2 * v
                pixels.append(min(1, light + 0.13 * t))
                pixels.append(min(1, light * 0.8 + 0.1 * v))
                pixels.append(min(1, light * 0.65 + 0.14 * (1 - t)))
                pixels.append(1)
            }
        }
        let bytes = pixels.count * MemoryLayout<Float>.stride
        let texture = try gpu.makeOutputTexture(width: width, height: height)
        guard
            let input = pixels.withUnsafeBytes({ ptr in
                gpu.device.makeBuffer(
                    bytes: ptr.baseAddress!, length: bytes,
                    options: .storageModeShared)
            }), let processed = gpu.device.makeBuffer(length: bytes, options: .storageModePrivate),
            let command = gpu.queue.makeCommandBuffer()
        else {
            throw Failure.failed("GPU smoke frame allocation failed")
        }
        let outputSpace = try lut.encode(
            source: input, destination: processed,
            width: width, height: height, on: command, file: file)
        try gpu.encodeBufferToTexture(processed, destination: texture, on: command)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { finished in
                withExtendedLifetime((input, processed, texture)) {
                    if finished.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: Failure.failed(
                                finished.error?.localizedDescription ?? "GPU LUT-to-texture command failed"))
                    }
                }
            }
            command.commit()
        }
        // Verify the Metal texture has non-uniform content BEFORE Core Image.
        // This catches blank-frame regressions that the 2-pixel test missed.
        // Float32 RGBA is SIXTEEN bytes per pixel. The former [UInt8] array was
        // only four bytes per pixel and the getBytes() call wrote out-of-bounds.
        // A shared readback MTLBuffer is valid on discrete Intel/Radeon Macs.
        let readbackBytesPerRow = width * MemoryLayout<SIMD4<Float>>.stride
        guard
            let readbackBuffer = device.makeBuffer(
                length: readbackBytesPerRow * height, options: .storageModeShared),
            let readbackCmd = gpu.queue.makeCommandBuffer(),
            let blit = readbackCmd.makeBlitCommandEncoder()
        else {
            throw Failure.failed("GPU readback texture unavailable")
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readbackBuffer, destinationOffset: 0,
            destinationBytesPerRow: readbackBytesPerRow,
            destinationBytesPerImage: readbackBytesPerRow * height)
        blit.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readbackCmd.addCompletedHandler { finished in
                if finished.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: Failure.failed(
                            finished.error?.localizedDescription ?? "GPU readback failed"))
                }
            }
            readbackCmd.commit()
        }
        let metalPixels = readbackBuffer.contents().assumingMemoryBound(to: Float.self)
        func rgbaFloat(_ x: Int, _ y: Int) -> [Float] {
            let o = (y * width + x) * 4
            return [metalPixels[o + 0], metalPixels[o + 1], metalPixels[o + 2], metalPixels[o + 3]]
        }
        let a = rgbaFloat(8, 32), b = rgbaFloat(87, 32)
        let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        // Allow for signed-log dark values - check that pixels are finite and vary
        guard maxDiff > 0.01,
            a.allSatisfy({ $0.isFinite }),
            b.allSatisfy({ $0.isFinite }),
            a.contains(where: { $0 > 0 })
        else {
            throw Failure.failed(
                "LUT_GPU_FRAME_BLANK: GPU LUT produced uniform/zero pixels (left=\(a), right=\(b), maxDiff=\(maxDiff))")
        }
        // Cover the exact Core Image import + letterbox + display sRGB path.
        let converted = try MetalPreviewComposition.content(
            texture: texture, colorSpace: outputSpace.cgColorSpace)
        let composed = MetalPreviewComposition.letterbox(
            converted,
            width: width, height: height)
        // CIContext.render(to:commandBuffer:) into a Metal texture silently
        // writes zeros on Intel macOS (standalone repro: completed status,
        // all-zero BGRA). The synchronous bitmap render exercises the same
        // CI import + letterbox + sRGB conversion without that bug.
        let ci = CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        let displayBytesPerRow = width * 4
        var displayStorage = [UInt8](repeating: 0, count: displayBytesPerRow * height)
        displayStorage.withUnsafeMutableBytes { raw in
            ci.render(
                composed, toBitmap: raw.baseAddress!, rowBytes: displayBytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // BGRA8 with two different RGB vectors: not just a single luminance sample.
        let displayBytes = displayStorage
        func bgra(_ x: Int, _ y: Int) -> [Int] {
            let o = (y * width + x) * 4
            return (0..<4).map { Int(displayBytes[o + $0]) }
        }
        let left = bgra(8, 32), right = bgra(87, 32)
        guard zip(left.prefix(3), right.prefix(3)).contains(where: { abs($0.0 - $0.1) > 24 }),
            left[3] == 255, right[3] == 255
        else {
            throw Failure.failed(
                "LUT_GPU_DISPLAY_BLANK: BGRA8/sRGB presentation lost image detail (left=\(left), right=\(right))")
        }
        print("LUT_GPU_DISPLAY_PASS: real Core Image presentation has chroma and contrast")
        print("LUT_GPU_FRAME_PASS: Metal LUT output has detail (maxDiff=\(maxDiff))")
    }

    private static func makeCube(path: URL, size n: Int, sceneLinear: Bool) throws {
        var text = "TITLE \"Smoke test\"\nLUT_3D_SIZE \(n)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let u = Float(r) / Float(n - 1), v = Float(g) / Float(n - 1), w = Float(b) / Float(n - 1)
                    if sceneLinear {
                        let x = SIMD3<Float>(signedLogInverse(u), signedLogInverse(v), signedLogInverse(w))
                        let c = toEncodedSRGB(x)
                        text += "\(c.x) \(c.y) \(c.z)\n"
                    } else {
                        text += "\(u) \(v) \(w)\n"
                    }
                }
            }
        }
        try text.write(to: path, atomically: true, encoding: .utf8)
        if sceneLinear {
            let meta = """
                {"version":1,"input":"linear-rec2020","output":"srgb","shaper":"signed-log2-v1","role":"full-film-print"}
                """
            try meta.write(
                to: URL(fileURLWithPath: path.path + ".lut.json"),
                atomically: true, encoding: .utf8)
        }
    }
    private static func signedLogInverse(_ u: Float) -> Float {
        if u < 0.2 { return -(pow(2, ((0.2 - u) / 0.2) * log2(17)) - 1) / 8 }
        return (pow(2, ((u - 0.2) / 0.8) * log2(513)) - 1) / 8
    }
    private static func toEncodedSRGB(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD3<Float>(
            1.660227 * x.x - 0.587547 * x.y - 0.072839 * x.z,
            -0.124554 * x.x + 1.132926 * x.y - 0.008349 * x.z,
            -0.018155 * x.x - 0.100603 * x.y + 1.118998 * x.z
        )
        func encode(_ c: Float) -> Float {
            let y = max(0, c)
            return y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        }
        return SIMD3<Float>(encode(v.x), encode(v.y), encode(v.z))
    }
}
