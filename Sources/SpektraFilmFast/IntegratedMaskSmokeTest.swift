import Foundation
import CoreGraphics
import ImageIO

/// Native integration checks, including real Core ML prompts and optional model inference.
enum IntegratedMaskSmokeTest {
    private enum Failure: Error { case check(String) }
    static func run() async -> Int32 {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure.check(message) }
            print("MASK_CHECK_PASS \(message)"); fflush(stdout)
        }
        do {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--sam2-fixture"), index + 1 < args.count else {
                throw Failure.check("Missing --sam2-fixture")
            }
            let url = URL(fileURLWithPath: args[index + 1])
            try check(ModelCatalog.all.count == 5, "five exact Redlamp manifests bundled")
            try check(ModelCatalog.manifest("sam2.1-tiny")?.downloadBytes == 79_644_968, "SAM2 exact model payload")
            try check(RemovalRegion.largestPiece([false, false, false, false], width: 2, height: 2) == [false, false, false, false], "empty connected region stays empty")
            try check(HalfPrecision.float(0x3c00) == 1 && HalfPrecision.float(0xc000) == -2 && HalfPrecision.float(0x7c00).isInfinite,
                      "Intel binary16 conversion")
            var grade = LocalGradeRecord()
            for i in 0..<16 {
                var source = MaskSourceRecord(name: "\(i)", kind: i % 2 == 0 ? .radial : .linearGradient)
                source.radial?.center = NormalizedPoint(x: Double(i % 4) / 4, y: Double(i / 4) / 4)
                source.feather = 0.22
                source.blendMode = i % 4 == 0 ? .subtract : .add
                grade.masks.sources.append(source)
            }
            guard let gpu = MaskMetalEngine.shared?.renderCoverage(grade: grade, width: 160, height: 90) else {
                throw Failure.check("Fused GPU evaluator unavailable")
            }
            let cpu = RedlampMaskCoverage.coverage(for: grade, width: 160, height: 90)
            let error = zip(cpu, gpu).map { abs($0 - $1) }.max() ?? 1
            try check(error < 0.002, "16-mask fused CPU/GPU parity")
            let sixteenMasks = grade
            var depth = MaskSourceRecord(name: "Depth", kind: .raster)
            depth.raster = RasterMaskPayload(width: 16, height: 1, alpha: (0..<16).map { UInt8($0 * 17) })
            depth.aiRecipe = AIMaskRecipe(kind: .depthRange, depthLower: 0.3, depthUpper: 0.7)
            grade.masks.sources = [depth]
            let cpuDepth = RedlampMaskCoverage.coverage(for: grade, width: 16, height: 1)
            guard let gpuDepth = MaskMetalEngine.shared?.renderCoverage(grade: grade, width: 16, height: 1) else {
                throw Failure.check("Depth GPU unavailable")
            }
            try check((zip(cpuDepth, gpuDepth).map { abs($0 - $1) }.max() ?? 1) < 0.005, "depth range evaluated in fused GPU kernel")
            let encoded = try JSONEncoder().encode(grade)
            let decoded = try JSONDecoder().decode(LocalGradeRecord.self, from: encoded)
            try check(decoded == grade, "mask bitmap and recipe persist together")
            _ = MaskMetalEngine.shared?.renderCoverage(grade: sixteenMasks, width: 1080, height: 720)
            let start = Date()
            for _ in 0..<10 { _ = MaskMetalEngine.shared?.renderCoverage(grade: sixteenMasks, width: 1080, height: 720) }
            print(String(format: "MASK_FIT_CPU_READBACK_MS %.3f", Date().timeIntervalSince(start) * 100))

            let service = RedlampMaskService.shared
            let point = AIMaskRecipe(kind: .objects, prompts: [ImagePoint(x: 0.6, y: 0.45)])
            let preview = try await service.previewObject(point, url: url)
            try check(preview.coveredFraction > 0.005 && preview.coveredFraction < 0.5, "real SAM2 hover preview selects truck object")
            var box = AIMaskRecipe(kind: .objects)
            box.box = ImageRect(x: 0.45, y: 0.2, width: 0.45, height: 0.65)
            let boxed = try await service.previewObject(box, url: url)
            try check(boxed.coveredFraction > 0.005 && boxed.pixels != preview.pixels, "real SAM2 box prompt")
            var negative = point
            negative.excluded = [ImagePoint(x: 0.68, y: 0.5)]
            let excluded = try await service.previewObject(negative, url: url)
            try check(excluded.pixels != preview.pixels, "real SAM2 negative prompt")
            let object = try await service.compute(point, url: url)
            try check(object.first?.mask.coveredFraction ?? 0 > 0.005, "object closed-form matte")
            var brushed = point
            brushed.refineStrokes = [BrushStroke(points: [ImagePoint(x: 0.55, y: 0.4), ImagePoint(x: 0.67, y: 0.5)], size: 0.025)]
            let objectMask = object[0].mask
            let objectRaster = RasterMaskPayload(width: objectMask.width, height: objectMask.height, alpha: objectMask.pixels)
            let edgeBrush = try await service.refine(objectRaster, recipe: brushed, url: url, onlyStrokes: true)
            try check(edgeBrush.width == objectMask.width && edgeBrush.height == objectMask.height && edgeBrush.coveredFraction > 0,
                      "full-size refine edge brush replay")
            let subject = try await service.compute(AIMaskRecipe(kind: .subject), url: url)
            let background = try await service.compute(AIMaskRecipe(kind: .background), url: url)
            if let a = subject.first?.mask, let b = background.first?.mask {
                try check(a.width == b.width && a.height == b.height && zip(a.pixels, b.pixels).allSatisfy { Int($0) + Int($1) == 255 },
                          "Vision subject/background complementary saved mattes")
            } else { throw Failure.check("Subject/background missing") }
            guard let skyIndex = args.firstIndex(of: "--sky-fixture"), skyIndex + 1 < args.count else {
                throw Failure.check("Missing --sky-fixture (use a photo containing sky)")
            }
            let skyURL = URL(fileURLWithPath: args[skyIndex + 1])
            let sky = try await service.compute(AIMaskRecipe(kind: .sky), url: skyURL)
            try check(sky.first?.mask.coveredFraction ?? 0 > 0.001, "SAM2/classical sky with full-size color matting")

            if args.contains("--test-optional-models") {
                for id in ["depth-anything-v2-small", "depth-anything-3-mono-large", "vitmatte-base", "sam3"] {
                    guard let manifest = ModelCatalog.manifest(id) else { throw Failure.check("Missing \(id)") }
                    try check(MaskModelStore.installed(manifest), "optional model verified: \(id)")
                }
                let depth = try await service.compute(AIMaskRecipe(kind: .depthRange), url: url)
                try check(depth.first?.mask.coveredFraction ?? 0 > 0, "Depth Anything 3 real inference")
                // The truck image contains vegetation and buildings; use a present landscape class.
                let landscape = try await service.compute(AIMaskRecipe(kind: .landscape, landscape: .vegetation), url: skyURL)
                try check(landscape.first?.mask.coveredFraction ?? 0 > 0.001, "SAM3 landscape real inference and matte")
                let analysis = try await service.analysisImage(url)
                let vitManifest = ModelCatalog.manifest("vitmatte-base")!
                let vit = try ViTMatte(manifest: vitManifest, directory: MaskModelStore.directory(vitManifest))
                let matte = try vit.refine(subject[0].mask, image: analysis)
                try check(matte.coveredFraction > 0.001 && matte.coveredFraction < 0.95, "ViTMatte direct nonempty real inference")
                let manifest = ModelCatalog.manifest("depth-anything-v2-small")!
                let v2 = try DepthEstimator(manifest: manifest, directory: MaskModelStore.directory(manifest))
                let result = try v2.depth(of: analysis)
                try check(result.coveredFraction > 0 && result.coveredFraction < 1, "Depth Anything V2 Small real inference")
            }
            print("MASK_INTEGRATION_PASS"); fflush(stdout)
            return 0
        } catch {
            print("MASK_INTEGRATION_FAIL \(error)"); fflush(stdout)
            return 25
        }
    }
}
