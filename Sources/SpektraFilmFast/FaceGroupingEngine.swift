import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Local-only organizational face clustering. Never identifies anyone by name.
/// Apple Vision image feature prints are *generic image* embeddings, not calibrated
/// biometric identity embeddings. We use two normalized crops, check co-occurrence,
/// then perform a guarded second pass. Uncertain identities remain split for review.
actor FaceGroupingEngine {
    private struct Sample {
        let photoID: UUID
        let prints: [VNFeaturePrintObservation]
        let area: Double
    }

    private struct Cluster {
        var samples: [Sample]
        var allPhotoIDs: Set<UUID>
        var coverID: UUID
        var coverArea: Double

        init(_ sample: Sample) {
            samples = [sample]
            allPhotoIDs = [sample.photoID]
            coverID = sample.photoID
            coverArea = sample.area
        }
        mutating func add(_ sample: Sample) {
            allPhotoIDs.insert(sample.photoID)
            if sample.area > coverArea {
                coverArea = sample.area
                coverID = sample.photoID
            }
            samples.append(sample)
            samples.sort { $0.area > $1.area }
            if samples.count > 10 { samples.removeLast(samples.count - 10) }
        }
        mutating func absorb(_ other: Cluster) {
            allPhotoIDs.formUnion(other.allPhotoIDs)
            if other.coverArea > coverArea {
                coverArea = other.coverArea
                coverID = other.coverID
            }
            samples.append(contentsOf: other.samples)
            samples.sort { $0.area > $1.area }
            if samples.count > 12 { samples.removeLast(samples.count - 12) }
        }
    }

    // The thresholds are intentionally distinct: the second pass requires multiple
    // independent witnesses when it uses a looser face/pose tolerance.
    private let directDistance: Float = 0.60
    private let consolidationDistance: Float = 0.70

    func group(items: [(UUID, URL)]) -> [PersonGroup] {
        var samples: [Sample] = []
        samples.reserveCapacity(items.count)
        for (id, url) in items {
            if Task.isCancelled { return [] }
            samples.append(contentsOf: featurePrints(photoID: id, url: url))
        }
        samples.sort { $0.area > $1.area }
        var groups: [Cluster] = []
        for sample in samples {
            if Task.isCancelled { return [] }
            var chosen: Int?
            var best = Float.greatestFiniteMagnitude
            for index in groups.indices {
                // A single face cannot be assigned to a cluster that already has
                // another face from the same photo. This prevents identity collapse.
                guard !groups[index].allPhotoIDs.contains(sample.photoID) else { continue }
                var distances: [Float] = []
                distances.reserveCapacity(groups[index].samples.count)
                for otherSample in groups[index].samples {
                    if let d = distance(otherSample, sample) { distances.append(d) }
                }
                distances.sort()
                guard let nearest = distances.first else { continue }
                let support = distances.prefix(3)
                let mean = support.reduce(Float(0), +) / Float(support.count)
                guard nearest < directDistance, mean < directDistance + 0.055 else { continue }
                if mean < best { best = mean; chosen = index }
            }
            if let chosen { groups[chosen].add(sample) }
            else { groups.append(Cluster(sample)) }
        }

        // Consolidate split identities across different lighting/camera viewpoints.
        // Two independent photos must corroborate a borderline merge; overlap of
        // photos is forbidden because these clusters may be different co-appearing people.
        var merged = true
        while merged {
            if Task.isCancelled { return [] }
            merged = false
            guard groups.count > 1 else { break }
            outer: for a in 0..<(groups.count - 1) {
                for b in (a + 1)..<groups.count {
                    guard groups[a].allPhotoIDs.isDisjoint(with: groups[b].allPhotoIDs) else { continue }
                    var witnesses = Set<UUID>()
                    var peerPhotos = Set<UUID>()
                    var distances: [Float] = []
                    for left in groups[a].samples {
                        for right in groups[b].samples {
                            guard let d = distance(left, right), d < consolidationDistance else { continue }
                            witnesses.insert(left.photoID)
                            peerPhotos.insert(right.photoID)
                            distances.append(d)
                        }
                    }
                    let strong = distances.contains { $0 <= directDistance * 0.88 }
                    let enough = witnesses.count >= 2 && peerPhotos.count >= 2 && distances.count >= 3
                    guard strong || enough else { continue }
                    let median = distances.sorted()[distances.count / 2]
                    guard median <= consolidationDistance - 0.035 else { continue }
                    groups[a].absorb(groups[b])
                    groups.remove(at: b)
                    merged = true
                    break outer
                }
            }
        }

        return groups.filter { $0.allPhotoIDs.count >= 2 }
            .sorted {
                if $0.allPhotoIDs.count != $1.allPhotoIDs.count {
                    return $0.allPhotoIDs.count > $1.allPhotoIDs.count
                }
                return $0.coverArea > $1.coverArea
            }
            .enumerated().map { index, cluster in
                PersonGroup(
                    name: "Person \(index + 1)",
                    imageIDs: cluster.allPhotoIDs,
                    coverImageID: cluster.coverID,
                    detectedFaceCount: cluster.allPhotoIDs.count
                )
            }
    }

    private func distance(_ a: Sample, _ b: Sample) -> Float? {
        guard !a.prints.isEmpty, !b.prints.isEmpty else { return nil }
        var distances: [Float] = []
        for i in 0..<min(a.prints.count, b.prints.count) {
            var value: Float = 0
            if (try? a.prints[i].computeDistance(&value, to: b.prints[i])) != nil,
               value.isFinite { distances.append(value) }
        }
        guard !distances.isEmpty else { return nil }
        distances.sort()
        // Consistent crop pairs. Keep the tighter crop's match, but penalize a
        // contradictory second crop so background/clothing won't dominate.
        if distances.count == 1 { return distances[0] }
        return distances[0] * 0.80 + distances[1] * 0.20
    }

    private func featurePrints(photoID: UUID, url: URL) -> [Sample] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return [] }
        let detector = VNDetectFaceRectanglesRequest()
        detector.revision = VNDetectFaceRectanglesRequestRevision3
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([detector])) != nil else { return [] }
        var result: [Sample] = []
        for face in detector.results ?? [] {
            if Task.isCancelled { break }
            let area = Double(face.boundingBox.width * face.boundingBox.height)
            guard area >= 0.0035 else { continue }
            let faceRect = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
            var prints: [VNFeaturePrintObservation] = []
            // Two views, same order for each face: tight head and expanded context.
            for padding in [0.08, 0.24] {
                let dx = faceRect.width * padding
                let dy = faceRect.height * padding
                let rect = faceRect.insetBy(dx: -dx, dy: -dy)
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    .integral
                guard rect.width >= 40, rect.height >= 40,
                      let crop = image.cropping(to: rect) else { continue }
                let request = VNGenerateImageFeaturePrintRequest()
                if (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil,
                   let feature = request.results?.first { prints.append(feature) }
            }
            if !prints.isEmpty { result.append(Sample(photoID: photoID, prints: prints, area: area)) }
        }
        return result
    }
}
