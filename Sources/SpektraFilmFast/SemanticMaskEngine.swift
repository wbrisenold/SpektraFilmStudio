import Foundation
import CoreGraphics
import CoreVideo
import Vision
import SemanticMaskNative

actor SemanticMaskEngine {
    func clearCache() { cache.removeAll(keepingCapacity: false) }
    func invalidate(imageURL: URL) { cache = cache.filter { $0.key.path != imageURL.path } }
    private struct CacheKey:Hashable{let path:String;let stamp:Int64;let width:Int;let height:Int}
    private var cache:[CacheKey:CanonicalSemanticMaskSet]=[:]

    func analyze(imageURL:URL,cgImage:CGImage,targetLongEdge:Int=1080) async throws -> CanonicalSemanticMaskSet {
        let d=(try? FileManager.default.attributesOfItem(atPath:imageURL.path)[.modificationDate] as? Date) ?? nil
        let key=CacheKey(path:imageURL.path,stamp:Int64(d?.timeIntervalSince1970 ?? 0),width:cgImage.width,height:cgImage.height)
        if let v=cache[key]{return v}
        let w=cgImage.width,h=cgImage.height,rgba=try Self.rgba8(cgImage),dir=Self.modelDirectory()
        let biref=dir.appendingPathComponent("birefnet-lite-1024.onnx")
        let modnet=dir.appendingPathComponent("modnet_photographic.onnx"),schp={let new=dir.appendingPathComponent("schp-lip-20-int8-static.onnx");return FileManager.default.fileExists(atPath:new.path) ? new : dir.appendingPathComponent("schp-lip-20-int8-dynamic.onnx")}(),face=dir.appendingPathComponent("face_parsing_resnet18.onnx")
        var masks:[SemanticMaskKind:[UInt8]]=[:], provenance:[String]=[]
        if FileManager.default.fileExists(atPath:biref.path),let a=try? Self.runMatte(model:biref,rgba:rgba,w:w,h:h){masks[.subject]=a;masks[.background]=a.map{255-$0};provenance.append("BiRefNet-lite MIT") }
        else if FileManager.default.fileExists(atPath:modnet.path), let a=try? Self.runMatte(model:modnet,rgba:rgba,w:w,h:h) {masks[.subject]=a;masks[.background]=a.map{255-$0};provenance.append("MODNet Apache-2.0")}
        else {
            let a=try Self.visionPersonMask(cgImage)
            masks[.subject]=a
            masks[.background]=a.map{255-$0}
            provenance.append("Vision fallback")
        }
        if FileManager.default.fileExists(atPath:schp.path), let labels=try? Self.runLabels(model:schp,profile:.schpLIP20,rgba:rgba,w:w,h:h) {masks[.person]=Self.mask(labels,SemanticLabels.person);masks[.hair]=Self.mask(labels,SemanticLabels.hair);masks[.upperClothes]=Self.mask(labels,SemanticLabels.upperClothes);masks[.lowerClothes]=Self.mask(labels,SemanticLabels.lowerClothes);masks[.arms]=Self.mask(labels,SemanticLabels.arms);masks[.legs]=Self.mask(labels,SemanticLabels.legs);masks[.shoes]=Self.mask(labels,SemanticLabels.shoes);provenance.append("SCHP LIP-20 MIT")}
        if FileManager.default.fileExists(atPath:face.path), let faces=try? Self.faceCrops(cgImage) {
            var fSkin=[UInt8](repeating:0,count:w*h),fHair=fSkin,fEyes=fSkin,fLips=fSkin
            // Never treat an entire image with no detected face as a face crop.
            let work=faces
            for rect in work { guard let crop=cgImage.cropping(to:rect.integral) else{continue};let crgba=try Self.rgba8(crop);guard let labels=try? Self.runLabels(model:face,profile:.face19,rgba:crgba,w:crop.width,h:crop.height) else {continue};Self.composite(Self.mask(labels,SemanticLabels.faceSkin),cropW:crop.width,cropH:crop.height,into:&fSkin,fullW:w,fullH:h,rect:rect);Self.composite(Self.mask(labels,SemanticLabels.faceHair),cropW:crop.width,cropH:crop.height,into:&fHair,fullW:w,fullH:h,rect:rect);Self.composite(Self.mask(labels,SemanticLabels.faceEyes),cropW:crop.width,cropH:crop.height,into:&fEyes,fullW:w,fullH:h,rect:rect);Self.composite(Self.mask(labels,SemanticLabels.faceLips),cropW:crop.width,cropH:crop.height,into:&fLips,fullW:w,fullH:h,rect:rect)}
            masks[.eyes]=fEyes;masks[.lips]=fLips;masks[.hair]=Self.union(masks[.hair],fHair)
            var skin=Self.union(fSkin,Self.union(masks[.arms],masks[.legs]));for x in [masks[.hair],masks[.eyes],masks[.lips],masks[.upperClothes],masks[.lowerClothes],masks[.shoes]]{skin=Self.subtract(skin,x)};if let p=masks[.person]{skin=Self.intersect(skin,p)};masks[.skin]=skin;masks[.body]=Self.union(fSkin,Self.union(masks[.arms],masks[.legs]));provenance.append("CelebAMask-HQ BiSeNet MIT")
        }
        if let skin=masks[.skin]{masks[.skin]=SemanticMaskRefinement.refine(skin,width:w,height:h)}
        let result=CanonicalSemanticMaskSet(width:w,height:h,alphaByKind:masks,provenance:provenance);cache[key]=result;return result
    }

    func objectMask(cgImage: CGImage, normalizedPoint: CGPoint) throws -> [UInt8] {
        // Prefer bundled MobileSAM ONNX image encoder + single-mask decoder;
        // fall back to Apple Vision when model files are unavailable or incompatible.
        let folder = Self.modelDirectory()
        let encoder = folder.appendingPathComponent("mobile_sam_image_encoder.onnx")
        let decoder = folder.appendingPathComponent("sam_mask_decoder_single.onnx")
        if FileManager.default.fileExists(atPath: encoder.path),
           FileManager.default.fileExists(atPath: decoder.path),
           let rgba = try? Self.rgba8(cgImage) {
            var alpha = [UInt8](repeating: 0, count: cgImage.width * cgImage.height)
            var error = [CChar](repeating: 0, count: 1024)
            let rc = encoder.path.withCString { enc in
                decoder.path.withCString { dec in
                    rgba.withUnsafeBufferPointer { input in
                        alpha.withUnsafeMutableBufferPointer { result in
                            error.withUnsafeMutableBufferPointer { err in
                                sf_semantic_point_run(enc, dec, input.baseAddress,
                                    Int32(cgImage.width), Int32(cgImage.height),
                                    Float(normalizedPoint.x), Float(normalizedPoint.y),
                                    result.baseAddress, err.baseAddress, Int32(err.count))
                            }
                        }
                    }
                }
            }
            if rc == 0 { return alpha }
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw NSError(domain: "Spektra.Semantic", code: 40, userInfo: [NSLocalizedDescriptionKey: "No selectable foreground object was found at this point."])
        }
        let available = observation.allInstances
        guard !available.isEmpty else {
            throw NSError(domain: "Spektra.Semantic", code: 41, userInfo: [NSLocalizedDescriptionKey: "No foreground instances were detected in this photo."])
        }
        let sampled = Self.instanceIndex(pixelBuffer: observation.instanceMask, normalizedPoint: normalizedPoint)
        let chosen = sampled > 0 && available.contains(sampled) ? sampled : Self.nearestInstance(pixelBuffer: observation.instanceMask, normalizedPoint: normalizedPoint, allowed: available)
        guard chosen > 0 else {
            throw NSError(domain: "Spektra.Semantic", code: 42, userInfo: [NSLocalizedDescriptionKey: "Click directly on the foreground object you want to mask."])
        }
        let mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: chosen), from: handler)
        return PixelMaskResize.copy(pixelBuffer: mask, width: cgImage.width, height: cgImage.height)
    }

    private static func instanceIndex(pixelBuffer: CVPixelBuffer, normalizedPoint: CGPoint) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let x = min(width - 1, max(0, Int(normalizedPoint.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(normalizedPoint.y * CGFloat(height))))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent8:
            return Int(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x])
        case kCVPixelFormatType_OneComponent32Float:
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            return max(0, Int(row[x].rounded()))
        default:
            return 0
        }
    }

    private static func nearestInstance(pixelBuffer: CVPixelBuffer, normalizedPoint: CGPoint, allowed: IndexSet) -> Int {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return 0 }
        let stepX = 1.0 / CGFloat(width), stepY = 1.0 / CGFloat(height)
        for radius in 1...16 {
            let r = CGFloat(radius)
            let samples = [
                CGPoint(x: normalizedPoint.x-r*stepX,y: normalizedPoint.y), CGPoint(x: normalizedPoint.x+r*stepX,y: normalizedPoint.y),
                CGPoint(x: normalizedPoint.x,y: normalizedPoint.y-r*stepY), CGPoint(x: normalizedPoint.x,y: normalizedPoint.y+r*stepY),
                CGPoint(x: normalizedPoint.x-r*stepX,y: normalizedPoint.y-r*stepY), CGPoint(x: normalizedPoint.x+r*stepX,y: normalizedPoint.y-r*stepY),
                CGPoint(x: normalizedPoint.x-r*stepX,y: normalizedPoint.y+r*stepY), CGPoint(x: normalizedPoint.x+r*stepX,y: normalizedPoint.y+r*stepY)
            ]
            for point in samples where point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1 {
                let value = instanceIndex(pixelBuffer: pixelBuffer, normalizedPoint: point)
                if value > 0 && allowed.contains(value) { return value }
            }
        }
        return 0
    }

    private static func runLabels(model: URL, profile: SemanticModelProfile, rgba: [UInt8], w: Int, h: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: w * h)
        var error = [CChar](repeating: 0, count: 1024)
        let rc = model.path.withCString { path in
            rgba.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    error.withUnsafeMutableBufferPointer { err in
                        sf_semantic_labels_run(path, profile.rawValue, input.baseAddress, Int32(w), Int32(h), out.baseAddress, err.baseAddress, Int32(err.count))
                    }
                }
            }
        }
        if rc != 0 {
            let message = error.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "Semantic inference failed"
            }
            throw NSError(domain: "Spektra.Semantic", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return output
    }

    private static func runMatte(model: URL, rgba: [UInt8], w: Int, h: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: w * h)
        var error = [CChar](repeating: 0, count: 1024)
        let rc = model.path.withCString { path in
            rgba.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    error.withUnsafeMutableBufferPointer { err in
                        sf_semantic_matte_run(path, input.baseAddress, Int32(w), Int32(h), out.baseAddress, err.baseAddress, Int32(err.count))
                    }
                }
            }
        }
        if rc != 0 {
            let message = error.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "Semantic matte inference failed"
            }
            throw NSError(domain: "Spektra.Semantic", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return output
    }
    private static func modelDirectory()->URL{let b=Bundle.main.resourceURL?.appendingPathComponent("AIModels");if let b,FileManager.default.fileExists(atPath:b.path){return b};return URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/AIModels")}
    private static func mask(_ labels:[UInt8],_ wanted:Set<UInt8>)->[UInt8]{labels.map{wanted.contains($0) ? 255:0}}
    private static func union(_ a:[UInt8]?,_ b:[UInt8]?)->[UInt8]{let n=max(a?.count ?? 0,b?.count ?? 0);return (0..<n).map{max(a?[safe:$0] ?? 0,b?[safe:$0] ?? 0)}}
    private static func subtract(_ a:[UInt8],_ b:[UInt8]?)->[UInt8]{(0..<a.count).map{UInt8(max(0,Int(a[$0])-Int(b?[safe:$0] ?? 0)))}}
    private static func intersect(_ a:[UInt8],_ b:[UInt8])->[UInt8]{zip(a,b).map{min($0,$1)}}
    private static func composite(_ src:[UInt8],cropW:Int,cropH:Int,into dst:inout[UInt8],fullW:Int,fullH:Int,rect:CGRect){let x0=max(0,Int(rect.minX)),y0=max(0,Int(rect.minY));for y in 0..<min(cropH,fullH-y0){for x in 0..<min(cropW,fullW-x0){let di=(y0+y)*fullW+(x0+x),si=y*cropW+x;dst[di]=max(dst[di],src[si])}}}
    private static func faceCrops(_ image:CGImage)throws->[CGRect]{let req=VNDetectFaceRectanglesRequest();try VNImageRequestHandler(cgImage:image).perform([req]);let w=CGFloat(image.width),h=CGFloat(image.height);return (req.results ?? []).map{obs in let b=obs.boundingBox;let cx=(b.midX*w),cy=((1-b.midY)*h),side=max(b.width*w,b.height*h)*1.65;var r=CGRect(x:cx-side/2,y:cy-side/2,width:side,height:side);r=r.intersection(CGRect(x:0,y:0,width:w,height:h));return r}.filter{$0.width>16&&$0.height>16}}
    private static func visionPersonMask(_ image:CGImage)throws->[UInt8]{let req=VNGeneratePersonSegmentationRequest();req.qualityLevel = .balanced;req.outputPixelFormat=kCVPixelFormatType_OneComponent8;try VNImageRequestHandler(cgImage:image).perform([req]);guard let p=req.results?.first?.pixelBuffer else{return [UInt8](repeating:0,count:image.width*image.height)};return PixelMaskResize.copy(pixelBuffer:p,width:image.width,height:image.height)}
    private static func rgba8(_ image:CGImage)throws->[UInt8]{var b=[UInt8](repeating:0,count:image.width*image.height*4);guard let c=CGContext(data:&b,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw NSError(domain:"Spektra.Semantic",code:3,userInfo:nil)};c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return b}
}
private extension Array{subscript(safe i:Int)->Element?{indices.contains(i) ? self[i]:nil}}
enum PixelMaskResize {
    static func copy(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sw = CVPixelBufferGetWidth(pixelBuffer), sh = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sw > 0, sh > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [UInt8](repeating: 0, count: width * height) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        func sample(_ x: Int, _ y: Int) -> Double {
            let xx = min(sw - 1, max(0, x)), yy = min(sh - 1, max(0, y))
            switch format {
            case kCVPixelFormatType_OneComponent8:
                let row = base.advanced(by: yy * stride).assumingMemoryBound(to: UInt8.self)
                return Double(row[xx]) / 255.0
            case kCVPixelFormatType_OneComponent32Float:
                let row = base.advanced(by: yy * stride).assumingMemoryBound(to: Float.self)
                return Double(max(0, min(1, row[xx])))
            default:
                return 0
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = (Double(y) + 0.5) * Double(sh) / Double(max(1, height)) - 0.5
            let y0 = Int(floor(fy)), y1 = y0 + 1, ty = fy - Double(y0)
            for x in 0..<width {
                let fx = (Double(x) + 0.5) * Double(sw) / Double(max(1, width)) - 0.5
                let x0 = Int(floor(fx)), x1 = x0 + 1, tx = fx - Double(x0)
                let a = sample(x0, y0) * (1 - tx) + sample(x1, y0) * tx
                let b = sample(x0, y1) * (1 - tx) + sample(x1, y1) * tx
                let v = max(0, min(1, a * (1 - ty) + b * ty))
                out[y * width + x] = UInt8(clamping: Int((v * 255).rounded()))
            }
        }
        return out
    }
}
