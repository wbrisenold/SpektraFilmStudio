import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ProductionSelfTest {
    /// Exercises the same queue as the Export button, without substituting preview pixels.
    @MainActor
    static func runOriginalExport(model: AppModel) async -> Bool {
        struct Failure: LocalizedError { let errorDescription: String? }
        func argument(_ name: String) throws -> String {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: name), index + 1 < args.count else {
                throw Failure(errorDescription: "Missing \(name)")
            }
            return args[index + 1]
        }
        do {
            let source = URL(fileURLWithPath: try argument("--export-fixture"))
            let parent = URL(fileURLWithPath: try argument("--export-output"), isDirectory: true)
            guard FileManager.default.fileExists(atPath: source.path), model.rendererAvailable else {
                throw Failure(errorDescription: "Original or renderer unavailable")
            }
            // Unique output directory: never replace an existing user export.
            let root = parent.appendingPathComponent("CR3-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var image = ProjectImageRecord(sourcePath: source.path, captureDate: nil)
            image.selectedForExport = true
            model.project.images = [image]
            model.project.selectedImageID = nil
            model.project.preferences.autosaveEnabled = false
            model.isProjectDirty = false
            // A stale social-size queue cannot resume under a Full Size UI selection.
            var queuedSettings = ExportSettings()
            queuedSettings.resizeMode = .fitBox
            queuedSettings.resizeWidth = 1080
            queuedSettings.resizeHeight = 1350
            queuedSettings.destinationPath = root.path
            var queued = ExportJob(settings: queuedSettings, bypassImportTransform: false,
                items: [ExportQueueItem(image: image, destination: root.appendingPathComponent("stale.tif"))])
            queued.state = .stopped
            model.activeExportJob = queued
            model.project.exportSettings = queuedSettings
            model.project.exportSettings.resizeMode = .none
            model.resumeExport()
            guard model.exportQueueSettingsDiffer, !model.isExporting, model.exportTask == nil,
                  model.activeExportJob?.settings.resizeMode == .fitBox else {
                throw Failure(errorDescription: "Resume silently reused stale resize settings")
            }
            queued.items[0].state = .failed
            model.activeExportJob = queued
            model.retryFailedExports()
            guard !model.isExporting, model.exportTask == nil else {
                throw Failure(errorDescription: "Retry silently reused stale resize settings")
            }
            print("QUEUED_SETTINGS_MISMATCH_PASS: Full Size cannot resume/retry a stale social-size queue")
            var results: [[String: Any]] = []
            for (label, sixteen, resize) in [("full-16", true, false), ("full-8", false, false), ("2048-16", true, true)] {
                var settings = ExportSettings()
                settings.format = .tiff
                settings.tiff16Bit = sixteen
                settings.preserveMetadata = true
                settings.resizeMode = resize ? .longEdge : .none
                settings.resizeLongEdge = 2048
                settings.destinationPath = root.path
                settings.filenameTemplate = "{name}-" + label
                model.project.exportSettings = settings
                print("ORIGINAL_EXPORT_START \(label) original=\(source.path)")
                fflush(stdout)
                model.exportSelected()
                guard let task = model.exportTask else { throw Failure(errorDescription: "Queue did not start: \(model.status)") }
                await task.value
                guard let item = model.activeExportJob?.items.first, item.state == .completed,
                      let timing = item.timings else {
                    throw Failure(errorDescription: "Export failed: \(model.exportFailures) \(model.status)")
                }
                let url = URL(fileURLWithPath: item.destinationPath)
                guard let encoded = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any],
                      let decoded = CGImageSourceCreateImageAtIndex(encoded, 0, nil),
                      decoded.bitsPerComponent == (sixteen ? 16 : 8),
                      decoded.width == timing.outputWidth, decoded.height == timing.outputHeight,
                      resize ? max(decoded.width, decoded.height) == 2048
                             : (decoded.width == timing.sourceWidth && decoded.height == timing.sourceHeight) else {
                    throw Failure(errorDescription: "Encoded dimensions/depth do not match the original export request")
                }
                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let row: [String: Any] = ["variant": label, "destination": url.path,
                    "sourceWidth": timing.sourceWidth, "sourceHeight": timing.sourceHeight,
                    "outputWidth": decoded.width, "outputHeight": decoded.height,
                    "bitsPerComponent": decoded.bitsPerComponent, "bitsPerPixel": decoded.bitsPerPixel,
                    "bytes": timing.outputBytes, "compression": tiff?[kCGImagePropertyTIFFCompression] ?? -1,
                    "profile": props[kCGImagePropertyProfileName] ?? "unknown",
                    "decodeMs": timing.decodeMs, "renderMs": timing.renderMs, "wallMs": timing.wallMs]
                results.append(row)
                print("ORIGINAL_EXPORT_RESULT \(row)")
                fflush(stdout)
            }
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("results.json"))
            print("ORIGINAL_EXPORT_PASS results=\(root.path)")
            return true
        } catch {
            print("ORIGINAL_EXPORT_FAIL \(error.localizedDescription)")
            return false
        }
    }

    static func run() async -> Int32 {
        guard await AuditRegressionTests.run() else { return 19 }
        do {
            try GPUGradeRegressionTests.run()
            guard await runCacheRoundTrip() else {
                fputs("SELFTEST FAIL: local cache round-trip did not produce verified hits\n", stderr)
                return 18
            }
            guard runAutoWhiteBalanceSelfTest() else {
                fputs("SELFTEST FAIL: Auto WB did not reduce a synthetic color cast\n", stderr)
                return 17
            }
            let renderer = try NativeRenderer()
            let width = 320
            let height = 200
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let fx = Float(x) / Float(max(1, width - 1))
                    let fy = Float(y) / Float(max(1, height - 1))
                    pixels[i] = -0.02 + fx * 1.24
                    pixels[i + 1] = 0.01 + fy * 1.08
                    pixels[i + 2] = 0.04 + (fx * 0.6 + fy * 0.4) * 0.96
                    pixels[i + 3] = 1
                }
            }
            let input = PixelBufferF32(width: width, height: height, pixels: pixels)
            var look = RenderLook.defaults()
            look.normalizeForProOnly()
            let (output, diagnostics) = try await renderer.render(input, look: look)
            guard output.width == width, output.height == height,
                  output.pixels.count == pixels.count,
                  diagnostics.passCount > 0 else {
                fputs("SELFTEST FAIL: invalid output dimensions/diagnostics\n", stderr)
                return 21
            }
            var finite = true
            var difference = 0.0
            for i in stride(from: 0, to: output.pixels.count, by: 4) {
                let r = output.pixels[i]
                let g = output.pixels[i + 1]
                let b = output.pixels[i + 2]
                if !r.isFinite || !g.isFinite || !b.isFinite { finite = false; break }
                difference += Double(abs(r - pixels[i]) + abs(g - pixels[i + 1]) + abs(b - pixels[i + 2]))
            }
            guard finite, difference > 1.0 else {
                fputs("SELFTEST FAIL: renderer produced invalid or trivial output\n", stderr)
                return 22
            }
            let (cachedOutput, cachedDiagnostics) = try await renderer.render(input, look: look)
            guard cachedOutput.pixels == output.pixels,
                  cachedDiagnostics.passCount < diagnostics.passCount else {
                throw RendererError.renderFailed("Film stage cache changed pixels or failed reuse")
            }
            var printLook=look
            printLook.values["printExposureEv"] = .scalar(0.3)
            let (reusedPrint, _) = try await renderer.render(input, look: printLook)
            let (uncachedPrint, _) = try await renderer.render(input, look: printLook, useStageCache: false)
            guard reusedPrint.pixels == uncachedPrint.pixels else {
                throw RendererError.renderFailed("Print edit stage cache parity failed")
            }
            var grainLook=look
            grainLook.values["grainEnabled"] = .bool(true)
            grainLook.values["grainModel"] = .int(2)
            let interactive=InteractiveRenderPolicy.previewLook(from: grainLook, changedParameter: "filterMShift", rawField: nil)
            guard interactive.values["grainEnabled"] == .bool(true),
                  interactive.values["grainModel"] == .int(0),
                  interactive.values["fastSpatial"] == .bool(true),
                  grainLook.values["grainModel"] == .int(2) else {
                throw RendererError.renderFailed("Interactive grain changed saved export model")
            }
            print("STAGE CACHE / INTERACTIVE GRAIN PASS: exact reuse, print edits, export model preserved")
            var haloLook=look
            haloLook.values["halationEnabled"] = .bool(true)
            haloLook.values["halationScale"] = .scalar(14)
            haloLook.values["scatterScale"] = .scalar(16)
            let (referenceHalo, referenceHaloDiagnostics) = try await renderer.render(input, look: haloLook, useStageCache: false)
            haloLook.values["fastSpatial"] = .bool(true)
            let savedHalo = try JSONDecoder().decode(RenderLook.self, from: JSONEncoder().encode(haloLook))
            let (fastHalo, fastHaloDiagnostics) = try await renderer.render(input, look: savedHalo, useStageCache: false)
            var haloMaximum=0.0
            for i in referenceHalo.pixels.indices {
                guard fastHalo.pixels[i].isFinite else { throw RendererError.renderFailed("Non-finite fast halation") }
                if i % 4 == 3 {
                    guard fastHalo.pixels[i] == referenceHalo.pixels[i] else { throw RendererError.renderFailed("Fast halation changed alpha") }
                } else {
                    haloMaximum=max(haloMaximum,Double(abs(fastHalo.pixels[i]-referenceHalo.pixels[i]))/max(1,Double(abs(referenceHalo.pixels[i]))))
                }
            }
            guard haloMaximum <= 0.03, fastHaloDiagnostics.passCount > referenceHaloDiagnostics.passCount else {
                throw RendererError.renderFailed("Fast halation quality/path gate failed: \(haloMaximum)")
            }
            print("FAST HALATION PASS: saved setting, reduced GPU path, full-size core, maximum error \(haloMaximum)")
            var fastLook = look
            fastLook.values["fastDIR"] = .bool(true)
            let restored = try JSONDecoder().decode(RenderLook.self, from: JSONEncoder().encode(fastLook))
            var explicitLook = look
            explicitLook.values["dirCouplersDiffusionUm"] = .scalar(0)
            explicitLook.values["dirCouplersDiffusionTailUm"] = .scalar(0)
            let (fastOutput, fastDiagnostics) = try await renderer.render(input, look: restored)
            let (explicitOutput, _) = try await renderer.render(input, look: explicitLook)
            guard fastOutput.pixels == explicitOutput.pixels,
                  fastDiagnostics.passCount < diagnostics.passCount else {
                throw RendererError.renderFailed("Fast DIR persistence/chemistry bypass failed")
            }
            print("FAST DIR SELFTEST PASS: saved mode matches explicit non-spatial chemistry, fewer GPU passes")
            let (lutOutput, _) = try await renderer.render(input, look: look, useDensityLuts: true)
            var lutMaximum = 0.0
            var lutSquaredError = 0.0
            for i in output.pixels.indices where i % 4 != 3 {
                let actual = Double(lutOutput.pixels[i])
                let expected = Double(output.pixels[i])
                guard actual.isFinite else { throw RendererError.renderFailed("Non-finite density LUT output") }
                let error = abs(actual - expected) / max(1, abs(expected))
                lutMaximum = max(lutMaximum, error)
                lutSquaredError += error * error
            }
            let lutRMS = sqrt(lutSquaredError / Double(width * height * 3))
            guard lutMaximum <= 0.002, lutRMS <= 0.0001 else {
                throw RendererError.renderFailed("Density LUT parity failed: max \(lutMaximum), RMS \(lutRMS)")
            }
            print("DENSITY LUT SELFTEST PASS: maximum \(lutMaximum), RMS \(lutRMS)")
            try runExportRoundTrip(lutOutput, look: look)
            print(String(format: "SELFTEST PASS: Metal %.2f ms, %u passes", diagnostics.commandBufferMs, diagnostics.passCount))
            return 0
        } catch {
            fputs("SELFTEST FAIL: \(error.localizedDescription)\n", stderr)
            return 20
        }
    }
    private static func runExportRoundTrip(_ output: PixelBufferF32, look: RenderLook) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpektraExportTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (format, sixteen) in [(ExportFormat.jpeg, false), (.heic, false), (.tiff, false), (.tiff, true)] {
            var settings = ExportSettings()
            settings.format = format; settings.tiff16Bit = sixteen; settings.preserveMetadata = false
            let destination = root.appendingPathComponent("\(format.rawValue)-\(sixteen).img")
            try ExportWriter.write(output: output, look: look, sourceURL: root.appendingPathComponent("unused"), destination: destination, settings: settings)
            guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  decoded.width == output.width, decoded.height == output.height,
                  !sixteen || decoded.bitsPerComponent == 16 else { throw RendererError.renderFailed("Export file round trip failed") }
            do {
                try ExportWriter.write(output: output, look: look, sourceURL: root, destination: destination, settings: settings)
                throw RendererError.renderFailed("Export overwrote an existing file")
            } catch ExportWriterError.destinationExists { }
        }
        print("EXPORT SELFTEST PASS: JPEG, HEIC, TIFF 8/16-bit decode and overwrite protection")
    }

    private static func runAutoWhiteBalanceSelfTest() -> Bool {
        let width = 96
        let height = 64
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let texture = Float((x + y) % 17) / 500.0
                pixels[i] = 0.72 + texture
                pixels[i + 1] = 0.56 + texture * 0.8
                pixels[i + 2] = 0.44 + texture * 0.6
                pixels[i + 3] = 1
            }
        }
        let source = PixelBufferF32(width: width, height: height, pixels: pixels)
        let corrected = source.applyingAutoWhiteBalance()

        func imbalance(_ buffer: PixelBufferF32) -> Double {
            var r = 0.0, g = 0.0, b = 0.0
            let count = max(1, buffer.width * buffer.height)
            for i in stride(from: 0, to: buffer.pixels.count, by: 4) {
                r += Double(buffer.pixels[i])
                g += Double(buffer.pixels[i + 1])
                b += Double(buffer.pixels[i + 2])
            }
            r /= Double(count); g /= Double(count); b /= Double(count)
            return max(r, max(g, b)) - min(r, min(g, b))
        }

        let before = imbalance(source)
        let after = imbalance(corrected)
        guard before > 0.20, after < before * 0.35 else { return false }
        print(String(format: "AUTO WB SELFTEST PASS: imbalance %.4f -> %.4f", before, after))
        return true
    }

    private static func runCacheRoundTrip() async -> Bool {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.appendingPathComponent("SpektraFilmFast-cache-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: parent) }
            let root = try CacheLocation.root(parentPath: parent.path)
            let source = parent.appendingPathComponent("cache-source.jpg")
            try writeSyntheticJPEG(to: source, width: 96, height: 64)

            let thumbnails = ThumbnailPipeline.shared
            await thumbnails.configure(memoryMode: .automatic, totalDiskCacheGB: 2, root: root)
            await thumbnails.clearMemory()
            await thumbnails.clearDisk()
            let thumbBefore = await thumbnails.snapshot()
            _ = try await thumbnails.thumbnail(url: source, maxPixel: 64)
            await thumbnails.clearMemory() // second request must come from SSD, not RAM.
            _ = try await thumbnails.thumbnail(url: source, maxPixel: 64)
            let thumbAfter = await thumbnails.snapshot()
            guard thumbAfter.misses > thumbBefore.misses,
                  thumbAfter.hits > thumbBefore.hits,
                  thumbAfter.writes > thumbBefore.writes,
                  thumbAfter.diskBytes > 0 else { return false }

            let adjusted = RenderedPreviewDiskCache.shared
            await adjusted.configure(totalDiskCacheGB: 2, root: root)
            await adjusted.clear()
            let adjustedBefore = await adjusted.snapshot()
            let previewPixels = [Float](repeating: 0.72, count: 48 * 32 * 4)
            let previewData = previewPixels.withUnsafeBytes { Data($0) }
            let look = RenderLook.defaults()
            let previewEdge = 1800
            await adjusted.store(
                payload: FloatImagePayload(width: 48, height: 32, data: previewData),
                url: source,
                look: look,
                longEdge: previewEdge,
                bypassImportTransform: false,
                quality: .accurate
            )
            guard let accurateEntry = await adjusted.bestPreview(url: source, look: look, longEdge: previewEdge, bypassImportTransform: false),
                  accurateEntry.quality == .accurate,
                  let accurateBuffer = accurateEntry.payload.makePixelBuffer(),
                  accurateBuffer.pixels.first == 0.72 else { return false }
            let adjustedAfter = await adjusted.snapshot()
            guard adjustedAfter.writes > adjustedBefore.writes,
                  adjustedAfter.hits > adjustedBefore.hits,
                  adjustedAfter.diskBytes > 0 else { return false }
            await adjusted.invalidate(url: source)
            guard await adjusted.bestPreview(url: source, look: look, longEdge: previewEdge, bypassImportTransform: false) == nil else { return false }

            let cull = CullAnalysisDiskCache.shared
            await cull.configure(totalDiskCacheGB: 2, root: root)
            await cull.clear()
            let cullBefore = await cull.snapshot()
            let record = CullAnalysisRecord(
                score: 88,
                recommendation: .keep,
                sharpness: 0.82,
                faceSharpness: 0.80,
                exposureQuality: 0.91,
                highlightClipPercent: 0,
                shadowClipPercent: 0,
                noiseEstimate: 0.05,
                faceCount: 1,
                possibleBlink: false,
                perceptualHash: 0x1234,
                stackID: nil,
                stackRank: nil,
                stackCount: nil,
                reasons: ["self-test"],
                analyzedAt: Date()
            )
            await cull.store(record, url: source)
            guard await cull.analysis(url: source) == record else { return false }
            let cullAfter = await cull.snapshot()
            guard cullAfter.writes > cullBefore.writes,
                  cullAfter.hits > cullBefore.hits,
                  cullAfter.diskBytes > 0 else { return false }

            let developed = DevelopedSourceDiskCache.shared
            await developed.configure(totalDiskCacheGB: 2, root: root)
            await developed.clear()
            let decoder = ImageDecoder()
            let raw = RawSettings()
            let decodeBefore = await decoder.snapshot()
            _ = try await decoder.decode(url: source, longEdge: 72, raw: raw, bypassImportTransform: false, cacheMode: .automatic)
            _ = try await decoder.decode(url: source, longEdge: 72, raw: raw, bypassImportTransform: false, cacheMode: .automatic)
            let decodeAfter = await decoder.snapshot()
            guard decodeAfter.misses > decodeBefore.misses,
                  decodeAfter.hits > decodeBefore.hits,
                  decodeAfter.memoryBytes > 0 else { return false }

            // Force a persistent developed-source round trip at the normal preview request size.
            let developedBefore = await developed.snapshot()
            let sourceBuffer = PixelBufferF32(width: 64, height: 48, pixels: [Float](repeating: 0.42, count: 64 * 48 * 4))
            await developed.store(sourceBuffer, url: source, raw: raw, longEdge: 1800, bypassImportTransform: false)
            guard let restored = await developed.buffer(url: source, raw: raw, longEdge: 1800, bypassImportTransform: false),
                  restored.width == sourceBuffer.width,
                  restored.height == sourceBuffer.height,
                  restored.pixels.count == sourceBuffer.pixels.count else { return false }
            let developedAfter = await developed.snapshot()
            guard developedAfter.writes > developedBefore.writes,
                  developedAfter.hits > developedBefore.hits,
                  developedAfter.diskBytes > 0 else { return false }

            print("CACHE SELFTEST PASS: thumbnail SSD + developed-source SSD + adjusted SSD + Cull SSD + decode RAM hits verified")
            return true
        } catch {
            fputs("CACHE SELFTEST ERROR: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static func writeSyntheticJPEG(to url: URL, width: Int, height: Int) throws {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 255) / max(1, width - 1))
                bytes[i + 1] = UInt8((y * 255) / max(1, height - 1))
                bytes[i + 2] = UInt8(((x + y) * 255) / max(1, width + height - 2))
                bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func runSoak(iterations: Int = 48) async -> Int32 {
        do {
            let renderer = try NativeRenderer()
            let width = 640
            let height = 360
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let fx = Float(x) / Float(max(1, width - 1))
                    let fy = Float(y) / Float(max(1, height - 1))
                    pixels[i] = 0.02 + fx * 1.08
                    pixels[i + 1] = 0.02 + fy * 0.96
                    pixels[i + 2] = 0.02 + (fx * 0.45 + fy * 0.55) * 1.02
                    pixels[i + 3] = 1
                }
            }
            let input = PixelBufferF32(width: width, height: height, pixels: pixels)
            var totalGPU = 0.0
            var maxPasses: UInt32 = 0
            for n in 0..<iterations {
                var look = RenderLook.defaults()
                look.normalizeForProOnly()
                let phase = Double(n % 12) / 11.0
                look.values["filmExposureEv"] = .scalar(-1.5 + 3.0 * phase)
                look.values["filterMShift"] = .scalar(-18.0 + 36.0 * phase)
                look.values["filterYShift"] = .scalar(12.0 - 24.0 * phase)
                look.values["printerLightR"] = .scalar(-3.0 + 6.0 * phase)
                if n % 4 == 0 {
                    look.values["halationEnabled"] = .bool(true)
                    look.values["halationAmount"] = .scalar(0.35)
                }
                if n % 6 == 0 {
                    look.values["cameraDiffusionEnabled"] = .bool(true)
                    look.values["cameraDiffusionStrength"] = .scalar(0.20)
                }
                let (output, d) = try await renderer.render(input, look: look, time: Double(n) / 24.0)
                guard output.pixels.count == pixels.count, d.passCount > 0 else {
                    fputs("SOAK FAIL: invalid render at iteration \(n)\n", stderr)
                    return 31
                }
                for i in stride(from: 0, to: output.pixels.count, by: 4096) {
                    guard output.pixels[i].isFinite else {
                        fputs("SOAK FAIL: non-finite output at iteration \(n)\n", stderr)
                        return 32
                    }
                }
                totalGPU += d.commandBufferMs
                maxPasses = max(maxPasses, d.passCount)
            }
            print(String(format: "SOAK PASS: %d renders, mean GPU %.2f ms, max %u passes", iterations, totalGPU / Double(iterations), maxPasses))
            return 0
        } catch {
            fputs("SOAK FAIL: \(error.localizedDescription)\n", stderr)
            return 30
        }
    }

}
