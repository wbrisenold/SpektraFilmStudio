import Foundation
import ImageIO
import CoreGraphics
import Vision

/// Analyzes only the locally materialized proxy/thumbnail; never opens a RAW original.
struct StudioSceneInput: Sendable {
    let id: UUID
    let previewURL: URL
    let captureTime: Date
    let folder: String
}

struct StudioSceneSuggestion: Identifiable, Sendable {
    let filmIndex: Int
    let paperIndex: Int
    let filmName: String
    let paperName: String
    let why: String
    var id: String { "\(filmIndex)-\(paperIndex)" }
}

struct StudioSceneSet: Identifiable, Sendable {
    let id: UUID
    let imageIDs: [UUID]
    let label: String
    let explanation: String
    let suggested: [StudioSceneSuggestion]
    let topTags: [String]
    var count: Int { imageIDs.count }
}

actor StudioSceneIntelligence {
    static let shared = StudioSceneIntelligence()

    private struct Descriptor {
        let feature: VNFeaturePrintObservation
        let labels: [(String, Float)]
        let faces: Int
        let luma: Double
    }

    // This cache is actor-confined. Changed thumbnail bytes are a new fingerprint.
    private var cache: [String: Descriptor] = [:]
    private var cacheOrder: [String] = []
    private let maxCache = 800

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Grouping is conservative: visual evidence must support capture-session proximity.
    /// Similar outfits shot weeks apart are not silently treated as the same studio session.
    func group(_ photos: [StudioSceneInput], similarity: Float,
               films: [String], papers: [String]) async throws -> [StudioSceneSet] {
        let ordered = photos.sorted {
            if $0.captureTime == $1.captureTime { return $0.id.uuidString < $1.id.uuidString }
            return $0.captureTime < $1.captureTime
        }
        var groups: [[(StudioSceneInput, Descriptor)]] = []
        for item in ordered {
            try Task.checkCancellation()
            guard let descriptor = describe(item.previewURL) else { continue }
            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            // Avoid O(n²) over a full library; only consider sessions in the last 20 minutes.
            for index in groups.indices.reversed() {
                guard let latest = groups[index].last else { continue }
                let gap = abs(item.captureTime.timeIntervalSince(latest.0.captureTime))
                if gap > 20 * 60 { continue }
                if latest.0.folder != item.folder && gap > 90 { continue }
                guard let first = groups[index].first else { continue }
                // Complete-link witness: must be close to the first and the latest sample.
                guard let firstD = distance(descriptor, first.1),
                      let lastD = distance(descriptor, latest.1) else { continue }
                let difference = max(firstD, lastD)
                let sameFaceType = (descriptor.faces > 0) == (first.1.faces > 0)
                // Studio outfit/pose variations may have higher visual distance; nearby
                // frames of similar scene type receive a modest tolerance.
                let tolerance = gap < 120 && sameFaceType ? similarity + 0.12 : similarity
                guard difference <= tolerance else { continue }
                if difference < bestDistance { bestDistance = difference; bestIndex = index }
            }
            if let i = bestIndex { groups[i].append((item, descriptor)) }
            else { groups.append([(item, descriptor)]) }
        }
        return groups.map { group in
            let representative = group[group.count / 2]
            let allLabels = group.flatMap { $0.1.labels.prefix(4) }
            var weighted: [String: Float] = [:]
            for (name, value) in allLabels { weighted[name, default: 0] += value }
            let tags = weighted.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            let faceRatio = Double(group.filter { $0.1.faces > 0 }.count) / Double(max(group.count, 1))
            let luminance = group.map { $0.1.luma }.reduce(0, +) / Double(group.count)
            let label = Self.sceneTitle(tags: tags, faces: faceRatio, luma: luminance)
            let candidatePairs = Self.recommend(films: films, papers: papers, title: label,
                                                tags: tags, faceRatio: faceRatio, luma: luminance)
            let why = "\(group.count) photo\(group.count == 1 ? "" : "s") grouped by Vision image similarity, capture proximity and session folder. Review grouping before applying a look."
            return StudioSceneSet(id: representative.0.id,
                                  imageIDs: group.map { $0.0.id }, label: label,
                                  explanation: why, suggested: candidatePairs, topTags: tags)
        }
    }

    private func distance(_ first: Descriptor, _ second: Descriptor) -> Float? {
        var d: Float = 0
        guard (try? first.feature.computeDistance(&d, to: second.feature)) != nil, d.isFinite else { return nil }
        return d
    }

    private func describe(_ url: URL) -> Descriptor? {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path) else { return nil }
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(bytes)|\(modified)"
        if let old = cache[key] { return old }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384
              ] as CFDictionary) else { return nil }
        let feature = VNGenerateImageFeaturePrintRequest()
        feature.imageCropAndScaleOption = .scaleFit
        let classifier = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        // Feature-print similarity is essential, but classification and face detection
        // are optional enrichment. Older Intel systems should still be able to group
        // photos even when one of those auxiliary Vision requests is unavailable.
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([feature]) }
        catch { return nil }
        guard let observation = feature.results?.first else { return nil }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classifier])
        try? handler.perform([faces])
        let labels = (classifier.results ?? []).prefix(8).map { ($0.identifier, $0.confidence) }
        let description = Descriptor(feature: observation, labels: labels,
                                     faces: faces.results?.count ?? 0,
                                     luma: Self.estimatedLuminance(image))
        cache[key] = description
        cacheOrder.append(key)
        if cacheOrder.count > maxCache {
            for old in cacheOrder.prefix(cacheOrder.count - maxCache) { cache[old] = nil }
            cacheOrder.removeFirst(cacheOrder.count - maxCache)
        }
        return description
    }

    private nonisolated static func estimatedLuminance(_ image: CGImage) -> Double {
        // Small, bounded sRGB summary used only for suggestions. No changes to image pixels.
        let space = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let okay = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ptr = raw.baseAddress,
                  let context = CGContext(data: ptr, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 16 * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard okay else { return 0.5 }
        var total = 0.0
        for n in 0..<256 {
            let p = n * 4
            total += 0.2126 * Double(pixels[p]) + 0.7152 * Double(pixels[p + 1]) + 0.0722 * Double(pixels[p + 2])
        }
        return total / (256.0 * 255.0)
    }

    private nonisolated static func sceneTitle(tags: [String], faces: Double, luma: Double) -> String {
        let labels = tags.joined(separator: " ").lowercased()
        if labels.contains("studio") || labels.contains("fashion") || labels.contains("portrait") || faces > 0.6 {
            return "Studio / portraits"
        }
        if labels.contains("night") || labels.contains("dark") || luma < 0.20 { return "Night / low light" }
        if labels.contains("landscape") || labels.contains("mountain") || labels.contains("forest") || labels.contains("nature") { return "Outdoor / landscape" }
        if labels.contains("street") || labels.contains("city") || labels.contains("building") { return "City / street" }
        if labels.contains("product") || labels.contains("food") || labels.contains("still life") { return "Product / still life" }
        return "Mixed scene"
    }

    /// Style ranking, NOT a supervised film-stock model. Values are native catalog indices.
    /// Stock/paper names are taken from the pinned Spektrafilm core, never hard-coded as IDs.
    private nonisolated static func recommend(films: [String], papers: [String], title: String,
                                             tags: [String], faceRatio: Double, luma: Double) -> [StudioSceneSuggestion] {
        guard !films.isEmpty, !papers.isEmpty else { return [] }
        let studio = title.contains("Studio")
        let night = title.contains("Night")
        let outdoor = title.contains("Outdoor")
        let city = title.contains("City")
        // Returns the score *and* the evidence for it. A bare rank tells the
        // photographer nothing about why a film was chosen, which is the whole
        // point of asking the app.
        func filmScore(_ name: String) -> (score: Int, reasons: [String]) {
            let value = name.lowercased()
            var s = 0
            var reasons: [String] = []
            if studio {
                if value.contains("portra") || value.contains("portrait") {
                    s += 12; reasons.append("portrait emulsion suits a studio subject")
                }
                if value.contains("400h") || value.contains("pro 400") {
                    s += 9; reasons.append("neutral 400 for controlled white balance")
                }
                if value.contains("ektar") { s -= 3; reasons.append("Ektar is a landscape stock — weaker here") }
            }
            if outdoor {
                if value.contains("ektar") || value.contains("velvia") {
                    s += 11; reasons.append("saturated outdoor stock")
                }
                if value.contains("provia") || value.contains("100") {
                    s += 4; reasons.append("reversal-film character outdoors")
                }
            }
            if night {
                if value.contains("500t") || value.contains("tungsten") || value.contains("800") {
                    s += 12; reasons.append("tungsten-balanced for low light")
                }
                if value.contains("400") { s += 3; reasons.append("400 base suits dim scenes") }
            }
            if city {
                if value.contains("vision") || value.contains("400") {
                    s += 7; reasons.append("clean contrast for built subjects")
                }
            }
            if !studio && !night && !outdoor && !city {
                if value.contains("portra") || value.contains("400") { s += 3 }
            }
            if value.contains("color") { s += 1 }
            return (s, reasons)
        }
        func paperScore(_ name: String) -> (score: Int, reason: String?) {
            let value = name.lowercased()
            var s = 0
            var reason: String?
            if value.contains("endura") || value.contains("crystal") || value.contains("ra4") {
                s += 5; reason = "fiber/semi-fibre base holds highlights"
            }
            if studio && (value.contains("portrait") || value.contains("lustre")) {
                s += 4; reason = "smooth lustre surface for skin tones"
            }
            if outdoor && (value.contains("gloss") || value.contains("vivid")) { s += 3 }
            return (s, reason)
        }
        let sceneReason = studio ? "scene reads as a studio portrait (\(Int((faceRatio * 100).rounded()))% with faces)"
                  : night ? "scene reads as low light (mean luma \(String(format: "%.2f", luma)))"
                  : outdoor ? "scene reads as outdoor daylight"
                  : city ? "scene reads as an urban/subject environment"
                  : "no dominant scene cues; ranked neutrally"
        let filmOrder = films.indices.sorted { a, b in
            let lhs = filmScore(films[a]).score, rhs = filmScore(films[b]).score
            return lhs == rhs ? a < b : lhs > rhs
        }
        let paperOrder = papers.indices.sorted { a, b in
            let lhs = paperScore(papers[a]).score, rhs = paperScore(papers[b]).score
            return lhs == rhs ? a < b : lhs > rhs
        }
        return filmOrder.prefix(3).enumerated().map { position, filmIndex in
            let paperIndex = paperOrder[min(position, paperOrder.count - 1)]
            let evidence = filmScore(films[filmIndex]).reasons
            let paperWhy = paperScore(papers[paperIndex]).reason
            // Say what actually drove this pick. "General starting point" told the
            // user nothing they could not have guessed.
            let why = "\(sceneReason). " + (evidence.isEmpty
                ? "No strong match — this is catalog order, not a match."
                : evidence.joined(separator: "; ")) + ". " + (paperWhy ?? "paired paper by catalog order")
            return StudioSceneSuggestion(filmIndex: filmIndex, paperIndex: paperIndex,
                                         filmName: films[filmIndex], paperName: papers[paperIndex], why: why)
        }
    }
}
