import Foundation
import SemanticMaskNative

/// Behavioral tests for the concrete crash and integrity boundaries found in the audit.
@MainActor
enum AuditRegressionTests {
    static func run() -> Bool {
        func check(_ label: String, _ value: Bool) -> Bool {
            print("AUDIT \(value ? "PASS" : "FAIL"): \(label)")
            return value
        }
        guard check("damaged cache headers and valid round trips", CacheCodecAudit.run()),
              check("HTTP length overflow and ambiguous framing", ProofDockAudit.run()),
              check("stale Oracle session callbacks", OracleRcloneTerminal.runAuditRegressionTest()) else { return false }
        guard check("native mask null inputs rejected", sf_semantic_matte_run(nil, nil, 0, 0, nil, nil, 0) != 0 &&
                    sf_semantic_labels_run(nil, 1, nil, 0, 0, nil, nil, 0) != 0) else { return false }
        do {
            var project = SpektraProjectDocument()
            let image = ProjectImageRecord(sourcePath: "/tmp/audit-photo.jpg", captureDate: nil)
            project.images = [image, image]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                _ = try decoder.decode(SpektraProjectDocument.self, from: data)
                return check("duplicate project photo IDs rejected", false)
            } catch DecodingError.dataCorrupted { }
            guard check("duplicate project photo IDs rejected", true) else { return false }
            var settings = ExportSettings()
            settings.destinationPath = "/tmp/SpektraAudit-NoWrites"
            settings.sequenceStart = Int.max
            do {
                _ = try ExportJobPlanner.makeJob(images: [image, image], settings: settings, bypassImportTransform: false)
                return check("export sequence overflow rejected", false)
            } catch ExportPlanningError.invalidSequence { }
            settings.sequenceStart = 1
            settings.resizeMode = .longEdge
            settings.resizeLongEdge = Int.max
            do {
                _ = try PixelBufferF32(width: 1, height: 1).resizedForExport(settings: settings)
                return check("extreme export size rejected", false)
            } catch MetalExportResizer.ScaleError.oversized { }
            guard check("export sequence and size overflow rejected", true) else { return false }
            let geometry = StudioOutputGeometry.calculate(sourceWidth: 6000, sourceHeight: 4000,
                mode: .longEdge, width: Int.max, height: Int.max, longEdge: Int.max, dontEnlarge: false)
            guard check("extreme preview dimensions bounded", geometry.width <= 16384 && geometry.height <= 16384) else { return false }
            let crop = try JSONDecoder().decode(ExportSettings.self, from: Data("{\"jpegQuality\":1e300}".utf8))
            return check("persisted JPEG quality bounded", crop.jpegQuality == 1)
        } catch {
            print("AUDIT FAIL: \(error.localizedDescription)")
            return false
        }
    }
}
