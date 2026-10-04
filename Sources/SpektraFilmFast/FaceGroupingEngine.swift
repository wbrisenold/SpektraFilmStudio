import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Local-only people grouping for Library organization.
///
/// This is intentionally an organizational similarity tool, not biometric identification.
/// Faces are detected with Apple Vision, cropped locally, converted to Vision image feature
/// prints, then conservatively clustered by feature-print distance. No face data leaves the Mac.
actor FaceGroupingEngine {
    private struct FaceSample {
        let imageID: UUID
        let featurePrint: VNFeaturePrintObservation
        let faceArea: Double
    }

    private struct Cluster {
        var samples: [FaceSample]
        var imageIDs: Set<UUID>
        var coverImageID: UUID
        var largestFaceArea: Double

        mutating func add(_ sample: FaceSample) {
            samples.append(sample)
            imageIDs.insert(sample.imageID)
            if sample.faceArea > largestFaceArea {
                largestFaceArea = sample.faceArea
                coverImageID = sample.imageID
            }
            // A few varied examples improve matching without letting huge shoots make every
            // comparison progressively more expensive.
            if samples.count > 5 {
                samples.sort { $0.faceArea > $1.faceArea }
                samples.removeLast(samples.count - 5)
            }
        }
    }

    /// Lower is more similar for Vision feature prints. A conservative threshold avoids merging
    /// people merely because lighting/pose is similar. Users can rebuild groups at any time.
    private let matchThreshold: Float = 0.52

    func group(items: [(UUID, URL)]) -> [PersonGroup] {
        var samples: [FaceSample] = []
        samples.reserveCapacity(items.count)

        for (imageID, url) in items {
            if Task.isCancelled { return [] }
            samples.append(contentsOf: featurePrints(imageID: imageID, url: url))
        }

        // Start with the largest/cleanest faces so each cluster's first representatives are useful.
        samples.sort { $0.faceArea > $1.faceArea }
        var clusters: [Cluster] = []

        for sample in samples {
            if Task.isCancelled { return [] }
            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude

            for index in clusters.indices {
                var localBest = Float.greatestFiniteMagnitude
                for representative in clusters[index].samples {
                    var distance: Float = 0
                    if (try? sample.featurePrint.computeDistance(&distance, to: representative.featurePrint)) != nil {
                        localBest = min(localBest, distance)
                    }
                }
                if localBest < bestDistance {
                    bestDistance = localBest
                    bestIndex = index
                }
            }

            if let bestIndex, bestDistance <= matchThreshold {
                clusters[bestIndex].add(sample)
            } else {
                clusters.append(Cluster(
                    samples: [sample],
                    imageIDs: Set([sample.imageID]),
                    coverImageID: sample.imageID,
                    largestFaceArea: sample.faceArea
                ))
            }
        }

        // Repeated appearances are the useful Library groups. Single appearances are left out so
        // the sidebar does not fill with hundreds of one-photo identities.
        let repeated = clusters
            .filter { $0.imageIDs.count >= 2 }
            .sorted {
                if $0.imageIDs.count != $1.imageIDs.count { return $0.imageIDs.count > $1.imageIDs.count }
                return $0.largestFaceArea > $1.largestFaceArea
            }

        return repeated.enumerated().map { offset, cluster in
            PersonGroup(
                name: "Person \(offset + 1)",
                imageIDs: cluster.imageIDs,
                coverImageID: cluster.coverImageID,
                detectedFaceCount: cluster.samples.count
            )
        }
    }

    private func featurePrints(imageID: UUID, url: URL) -> [FaceSample] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }

        let request = VNDetectFaceRectanglesRequest()
        if #available(macOS 15.0, *) {
            request.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        var output: [FaceSample] = []
        for face in request.results ?? [] {
            if Task.isCancelled { break }
            let normalizedArea = Double(face.boundingBox.width * face.boundingBox.height)
            guard normalizedArea >= 0.006 else { continue }

            var rect = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
            let paddingX = rect.width * 0.18
            let paddingY = rect.height * 0.22
            rect = rect.insetBy(dx: -paddingX, dy: -paddingY)
            rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
            guard rect.width >= 32, rect.height >= 32, let crop = image.cropping(to: rect) else { continue }

            let printRequest = VNGenerateImageFeaturePrintRequest()
            let printHandler = VNImageRequestHandler(cgImage: crop, options: [:])
            guard (try? printHandler.perform([printRequest])) != nil,
                  let featurePrint = printRequest.results?.first else { continue }
            output.append(FaceSample(imageID: imageID, featurePrint: featurePrint, faceArea: normalizedArea))
        }
        return output
    }
}
