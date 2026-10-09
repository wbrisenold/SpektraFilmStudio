import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import AVFoundation

/// Adapts Redlamp's mask providers to Spektra's persisted local grades.
/// Models always see the oriented, unedited photo in sRGB.
actor RedlampMaskService {
    static let shared = RedlampMaskService()
    private var imageURL: URL?
    private var imageStamp: Date?
    private var image: CGImage?
    private var analysisPhoto: CGImage?
    private var sam: SAMSegmenter?
    private var embedding: SAMSegmenter.Embedding?
    private var concepts: SAM3Concepts?
    private var conceptFeatures: SAM3Concepts.Features?
    private var cachedClasses: [LandscapeClass: GrayMask]?
    private var cachedParts: SAM3Concepts.PeopleParts?
    private var cachedDepth: DepthAnything3.Result?
    private var depth3: DepthAnything3?
    private var depth2: DepthEstimator?
    private var vit: ViTMatte?
    private var foregroundMatte: GrayMask?
    private let vision = VisionMaskProvider()

    func invalidateComputedMasks() {
        embedding = nil; conceptFeatures = nil; cachedClasses = nil; cachedParts = nil; cachedDepth = nil
        sam = nil; concepts = nil; depth3 = nil; depth2 = nil; vit = nil; foregroundMatte = nil
    }

    private func original(_ url: URL) throws -> CGImage {
        let stamp = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if imageURL == url, imageStamp == stamp, let image { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ModelStoreError.download("Cannot open the original photo for masking.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= (64 * 1024 * 1024) / height else {
            throw ModelStoreError.download("AI masks support originals up to 64 megapixels and 16,384 pixels per side.")
        }
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ModelStoreError.download("Cannot read the original photo for masking.") }
        imageURL = url; imageStamp = stamp; image = decoded; analysisPhoto = nil; foregroundMatte = nil
        embedding = nil; conceptFeatures = nil; cachedClasses = nil; cachedParts = nil; cachedDepth = nil
        return decoded
    }

    func analysisImage(_ url: URL) throws -> CGImage {
        let full = try original(url)
        if let analysisPhoto { return analysisPhoto }
        let size = PixelSize(width: full.width, height: full.height).fitted(within: PixelSize(width: 2048, height: 2048))
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
            bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ModelStoreError.download("Cannot prepare mask analysis") }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw ModelStoreError.download("Cannot prepare mask analysis") }
        analysisPhoto = result
        return result
    }

    private func installed(_ id: String) throws -> (ModelManifest, URL) {
        guard let manifest = ModelCatalog.manifest(id), MaskModelStore.installed(manifest) else {
            throw ModelStoreError.unknownModel(id)
        }
        return (manifest, MaskModelStore.directory(manifest))
    }

    private func segmenter() throws -> SAMSegmenter {
        if let sam { return sam }
        guard let manifest = ModelCatalog.manifest("sam2.1-tiny") else { throw ModelStoreError.unknownModel("sam2.1-tiny") }
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("AIModels/SAM2Tiny")
        let directory = FileManager.default.fileExists(atPath: bundled.path) ? bundled : try installed(manifest.id).1
        let loaded = try SAMSegmenter(manifest: manifest, directory: directory)
        sam = loaded
        return loaded
    }

    private func object(_ request: MaskRequest, image: CGImage) throws -> GrayMask {
        let sam = try segmenter()
        if embedding == nil { embedding = try sam.embedding(for: image) }
        return try sam.mask(embedding!, included: request.prompts, excluded: request.excluded, box: request.box,
                            size: PixelSize(width: image.width, height: image.height))
    }

    func previewObject(_ recipe: AIMaskRecipe, url: URL) throws -> GrayMask {
        try object(recipe.request, image: analysisImage(url))
    }

    func people(in url: URL) throws -> [PersonFound] { try vision.peopleFound(in: analysisImage(url)) }

    private func da3(_ image: CGImage) throws -> DepthAnything3.Result {
        if depth3 == nil {
            let (manifest, directory) = try installed("depth-anything-3-mono-large")
            depth3 = try DepthAnything3(manifest: manifest, directory: directory)
        }
        if let cachedDepth { return cachedDepth }
        let result = try depth3!.predict(image)
        cachedDepth = result
        return result
    }

    func compute(_ recipe: AIMaskRecipe, url: URL) throws -> [ProvidedMask] {
        let full = try original(url)
        let image = try analysisImage(url)
        let request = recipe.request
        var provided: [ProvidedMask]
        switch request.kind {
        case .subject, .background:
            provided = try vision.masks(for: request, in: image)
        case .people:
            if [.hair, .facialHair, .bodySkin, .clothes].contains(request.part) {
                if request.part == .hair, let matte = try embedded(url, type: kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte) {
                    provided = [ProvidedMask(kind: .people, provider: "apple.embedded.hair", revision: 14, part: .hair, mask: matte)]
                } else {
                    if concepts == nil {
                        let (manifest, directory) = try installed("sam3")
                        concepts = try SAM3Concepts(manifest: manifest, directory: directory)
                    }
                    if conceptFeatures == nil { conceptFeatures = try concepts!.features(of: image) }
                    if cachedParts == nil { cachedParts = try concepts!.peopleParts(conceptFeatures!) }
                    guard let part = cachedParts!.parts[request.part], let other = cachedParts!.others[request.part] else {
                        throw MaskComputationError.notFound(request.part)
                    }
                    let subject = try vision.masks(for: MaskRequest(kind: .people), in: image)
                    let person = subject.dropFirst().reduce(subject.first?.mask ?? part) { $0.union($1.mask) }
                    let matte = ClosedFormMatte.refine(person, image: full)
                    let dehazed = GrayMask(width: part.width, height: part.height, coverage: part.coverage.map { max($0 - 0.1, 0) / 0.9 })
                    let guided = GuidedFilter.refine(dehazed.resized(to: PixelSize(width: image.width, height: image.height)), guide: image, radius: 4, epsilon: 1e-3)
                    let mask = SAM3Concepts.edges(of: guided, others: other, person: matte, reach: max(1, image.width / 50))
                    provided = [ProvidedMask(kind: .people, provider: "redlamp.sam3", revision: 14, part: request.part, mask: mask)]
                }
            } else if request.part == .teeth, let teeth = try embedded(url, type: kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte) {
                provided = [ProvidedMask(kind: .people, provider: "apple.embedded.teeth", revision: 14, part: .teeth, mask: teeth)]
            } else { provided = try vision.masks(for: request, in: image) }
            if [.hair, .facialHair, .bodySkin, .clothes].contains(request.part), let combined = provided.first {
                let people = (try? vision.masks(for: MaskRequest(kind: .people), in: image)) ?? []
                if !people.isEmpty {
                    let size = PixelSize(width: combined.mask.width, height: combined.mask.height)
                    let pieces = combined.mask.split(among: people.map { $0.mask.resized(to: size) })
                    provided = zip(people, pieces).map { person, mask in
                        ProvidedMask(kind: .people, provider: combined.provider, revision: 14,
                                     instance: person.instance, part: request.part, mask: mask)
                    }
                }
            }
            if let selected = request.people { provided = provided.filter { $0.instance.map(selected.contains) ?? true } }
        case .objects:
            provided = [ProvidedMask(kind: .objects, provider: "redlamp.sam2.1-tiny", revision: 14,
                                     mask: try object(request, image: image))]
        case .sky:
            if let sky = try embedded(url, type: kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte) {
                provided = [ProvidedMask(kind: .sky, provider: "apple.embedded.sky", revision: 14,
                    mask: CoarseMaskEdges.refine(sky, analysis: image, full: full))]
                break
            }
            let depth = try? da3(image)
            var seeds = (try? SkyEstimator.seeds(image)) ?? []
            if seeds.isEmpty, let depth { seeds = (try? SkyEstimator.seeds(inside: depth.sky)) ?? [] }
            var mask: GrayMask
            if !seeds.isEmpty {
                let raw = try object(MaskRequest(kind: .objects, prompts: seeds), image: image)
                mask = SkyEstimator.refineBetweenBranches(GuidedFilter.refine(raw, guide: image, radius: 4, epsilon: 1e-3), image: image)
                if let depth { mask = SkyEstimator.arbitrate(mask, depth.sky) }
            } else if let depth { mask = depth.sky }
            else { mask = try SkyEstimator.estimate(image).mask }
            provided = [ProvidedMask(kind: .sky, provider: "Redlamp sky / SAM2 / optional DA3", revision: 14,
                                     mask: SkyMatte.refine(mask, image: full))]
        case .depthRange:
            let mask: GrayMask
            if let embedded = try embeddedDepth(url) { mask = embedded }
            else if let result = try? da3(image) { mask = result.depth }
            else {
                if depth2 == nil {
                    let (manifest, directory) = try installed("depth-anything-v2-small")
                    depth2 = try DepthEstimator(manifest: manifest, directory: directory)
                }
                mask = try depth2!.depth(of: image)
            }
            provided = [ProvidedMask(kind: .depthRange, provider: "Embedded depth / Redlamp Depth Anything", revision: 14, mask: mask)]
        case .landscape:
            if concepts == nil {
                let (manifest, directory) = try installed("sam3")
                concepts = try SAM3Concepts(manifest: manifest, directory: directory)
            }
            if conceptFeatures == nil { conceptFeatures = try concepts!.features(of: image) }
            if cachedClasses == nil { cachedClasses = try concepts!.classes(conceptFeatures!) }
            guard let mask = cachedClasses![request.landscape] else {
                throw MaskComputationError.notFound(request.landscape)
            }
            guard mask.coveredFraction > 0.001 else { throw MaskComputationError.notFound(request.landscape) }
            provided = [ProvidedMask(kind: .landscape, provider: "redlamp.sam3+closed-form", revision: 14,
                                     mask: ClosedFormMatte.refine(mask, image: full))]
        default: throw MaskComputationError.unsupported(request.kind)
        }
        return try provided.map { supplied in
            var result = supplied
            var mask = result.mask
            if mask.coveredFraction <= 0.0002, request.kind != .background { throw MaskComputationError.nothingFound(request.kind) }
            let wholePerson = request.kind == .people && request.part == .entirePerson
            if [.subject, .background, .objects].contains(request.kind) || wholePerson {
                let background = request.kind == .background
                if [.subject, .background].contains(request.kind), let foregroundMatte {
                    mask = foregroundMatte
                } else {
                if background { mask = mask.inverted }
                mask = ClosedFormMatte.refine(mask, image: full, inner: request.kind == .subject || background ? ClosedFormMatte.subjectInner : ClosedFormMatte.inner)
                if [.subject, .background, .people].contains(request.kind),
                   let manifest = ModelCatalog.manifest("vitmatte-base"), MaskModelStore.installed(manifest) {
                    if vit == nil { vit = try ViTMatte(manifest: manifest, directory: MaskModelStore.directory(manifest)) }
                    mask = ViTMatte.strands(of: try vit!.refine(background ? result.mask.inverted : result.mask, image: full), addedTo: mask)
                }
                if [.subject, .background].contains(request.kind) { foregroundMatte = mask }
                }
                if background { mask = mask.inverted }
            }
            if request.kind == .people && !wholePerson && !result.provider.contains("sam3") {
                mask = CoarseMaskEdges.refine(mask, analysis: image, full: full)
            }
            if !recipe.refineStrokes.isEmpty { mask = ClosedFormMatte.refine(mask, image: full, along: recipe.refineStrokes) }
            result.mask = mask
            return result
        }
    }

    func refine(_ raster: RasterMaskPayload, recipe: AIMaskRecipe, url: URL, onlyStrokes: Bool = false) throws -> GrayMask {
        let image = try original(url)
        let mask = GrayMask(width: raster.width, height: raster.height, pixels: raster.decodedAlpha())
        if recipe.kind == .depthRange { return mask }
        if onlyStrokes { return ClosedFormMatte.refine(mask, image: image, along: recipe.refineStrokes) }
        let background = recipe.kind == .background
        let coarse = background ? mask.inverted : mask
        var refined: GrayMask
        if recipe.kind == .sky {
            refined = SkyMatte.refine(coarse, image: image)
        } else if recipe.kind == .people && recipe.part != .entirePerson && !recipe.provider.contains("sam3") {
            refined = CoarseMaskEdges.refine(coarse, analysis: try analysisImage(url), full: image)
        } else {
            refined = ClosedFormMatte.refine(coarse, image: image,
                inner: recipe.kind == .subject || background ? ClosedFormMatte.subjectInner : ClosedFormMatte.inner)
            let wholePerson = recipe.kind == .people && recipe.part == .entirePerson
            if recipe.kind == .subject || background || wholePerson,
               let manifest = ModelCatalog.manifest("vitmatte-base"), MaskModelStore.installed(manifest) {
                if vit == nil { vit = try ViTMatte(manifest: manifest, directory: MaskModelStore.directory(manifest)) }
                refined = ViTMatte.strands(of: try vit!.refine(coarse, image: image), addedTo: refined)
            }
        }
        if background { refined = refined.inverted }
        if !recipe.refineStrokes.isEmpty { refined = ClosedFormMatte.refine(refined, image: image, along: recipe.refineStrokes) }
        return refined
    }

    private func orientation(_ source: CGImageSource) -> Int {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private func embedded(_ url: URL, type: CFString) throws -> GrayMask? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let data = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any] else { return nil }
        let matte = try AVSemanticSegmentationMatte(fromImageSourceAuxiliaryDataType: type, dictionaryRepresentation: data)
        return try VisionMaskProvider.gray(matte.mattingImage).oriented(exif: orientation(source))
    }

    private func embeddedDepth(_ url: URL) throws -> GrayMask? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let data = (CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth)) as? [AnyHashable: Any] else { return nil }
        let depth = try AVDepthData(fromDictionaryRepresentation: data).converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let buffer = depth.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let value = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)[x]
            values[y * width + x] = value.isFinite ? max(0, value) : 0
        } }
        let low = values.min() ?? 0, high = values.max() ?? 1
        return GrayMask(width: width, height: height, coverage: values.map { ($0 - low) / max(high - low, 1e-6) }).oriented(exif: orientation(source))
    }
}
