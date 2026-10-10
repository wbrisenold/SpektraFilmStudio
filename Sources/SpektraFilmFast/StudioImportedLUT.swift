import Foundation
import Metal
import CoreGraphics

// GPL-3.0. Imported 3D LUTs are an alternative to the *native film-and-print*
// stage. RAW development and host grade remain scene-linear Rec.2020.
// The explicit per-file contract prevents an encoded-sRGB LUT from ever being
// confused with a scene-linear Rec.2020 LUT. The LUT contains its own ODT.
enum StudioImportedLUT {
    static let folderKey = "SpektraFilmStudio.lutLibrary.folder.v1"
    static let selectionKey = "SpektraFilmStudio.lutLibrary.selected.v1"
    static let modeKey = "SpektraFilmStudio.preview.spectralLUT.v1"
    static let displayNameKey = "SpektraFilmStudio.lutLibrary.selectedDisplayName.v1"

    enum InputSpace: String, Codable, Sendable {
        case encodedSRGB = "srgb"
        case linearRec2020 = "linear-rec2020"
    }
    enum OutputSpace: String, Codable, Sendable {
        case encodedSRGB = "srgb"
        case linearRec2020 = "linear-rec2020"
        var cgColorSpace: CGColorSpace {
            switch self {
            case .encodedSRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .linearRec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
            }
        }
    }
    enum Shaper: String, Codable, Sendable {
        case encodedSRGB = "srgb-encoded"
        case signedLog2 = "signed-log2-v1"
        case domainLinear = "domain-linear"
    }
    enum Role: String, Codable, Sendable {
        case fullFilmPrint = "full-film-print"
    }
    struct Contract: Codable, Sendable {
        let version: Int
        let input: InputSpace
        let output: OutputSpace
        let shaper: Shaper
        let role: Role

        static let legacySRGB = Contract(version: 1, input: .encodedSRGB,
                                         output: .encodedSRGB,
                                         shaper: .encodedSRGB, role: .fullFilmPrint)
        func validate() throws {
            guard version == 1, role == .fullFilmPrint, output == .encodedSRGB else {
                throw Failure.invalid("Only version-1 full-film-print LUTs with encoded sRGB output are supported.")
            }
            guard (input == .encodedSRGB && shaper == .encodedSRGB) ||
                  (input == .linearRec2020 && shaper != .encodedSRGB) else {
                throw Failure.invalid("LUT input space and shaper are incompatible.")
            }
        }
    }
    struct Item: Identifiable, Hashable, Sendable {
        let id: String  // relative path within a selected library, never a guessed name
        let name: String
        let input: InputSpace
        let output: OutputSpace
        let shaper: Shaper
        let assumedSRGB: Bool
    }
    struct Cube: Sendable {
        let size: Int
        let values: [SIMD4<Float>]
        let domainMin: SIMD3<Float>
        let domainMax: SIMD3<Float>
        let contract: Contract
        let assumedSRGB: Bool
    }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return "Imported LUT: \(message)" }
        }
    }

    static var isSelected: Bool { UserDefaults.standard.string(forKey: modeKey) == "imported" }
    static var selectedDisplayName: String {
        let label = UserDefaults.standard.string(forKey: displayNameKey) ?? ""
        return label.isEmpty ? (selectedURL()?.deletingPathExtension().lastPathComponent ?? "unknown") : label
    }

    static func selectedURL() -> URL? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: modeKey) == "imported",
              let folder = defaults.string(forKey: folderKey), !folder.isEmpty,
              let selection = defaults.string(forKey: selectionKey), !selection.isEmpty,
              !selection.hasPrefix("/"), !selection.split(separator: "/").contains("..") else { return nil }
        let base = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        let url = base.appendingPathComponent(selection).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), url.pathExtension.lowercased() == "cube" else { return nil }
        return url
    }

    /// Folder index is intentionally metadata-first, with a safe sRGB legacy
    /// assumption. Selecting a legacy LUT exposes this assumption in Settings.
    static func discover(folder: URL) throws -> [Item] {
        let root = folder.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let scan = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles], errorHandler: nil) else {
            throw Failure.invalid("Unable to read the LUT library folder.")
        }
        var items: [Item] = []
        for case let url as URL in scan {
            guard url.pathExtension.lowercased() == "cube",
                  let props = try? url.resourceValues(forKeys: Set(keys)),
                  props.isRegularFile == true, props.isSymbolicLink != true,
                  (props.fileSize ?? 0) <= 48_000_000 else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, !relative.hasPrefix("../") else { continue }
            let (contract, assumed) = try readContract(for: url)
            items.append(Item(id: relative,
                              name: url.deletingPathExtension().lastPathComponent,
                              input: contract.input, output: contract.output,
                              shaper: contract.shaper, assumedSRGB: assumed))
            if items.count > 100_000 { throw Failure.invalid("Library exceeds 100,000 LUTs.") }
        }
        // Catalog descriptions take precedence over machine-generated filenames.
        // Identity remains the relative file path (never a display name).
        let labels = StudioLUTCatalog.metadata(for: root, relativeLUTs: items.map(\.id))
        return items.map { item in
            Item(id: item.id, name: labels[item.id]?.name ?? item.name,
                 input: item.input, output: item.output, shaper: item.shaper,
                 assumedSRGB: item.assumedSRGB)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func readContract(for url: URL) throws -> (Contract, Bool) {
        // The sidecar is `Film.cube.lut.json`, not a global default that could
        // silently misinterpret an sRGB LUT as linear Rec.2020.
        let sidecar = URL(fileURLWithPath: url.path + ".lut.json")
        guard FileManager.default.fileExists(atPath: sidecar.path) else {
            return (.legacySRGB, true)
        }
        let bytes = try Data(contentsOf: sidecar)
        guard bytes.count <= 16384 else { throw Failure.invalid("Oversized LUT contract: \(sidecar.lastPathComponent)") }
        let meta = try JSONDecoder().decode(Contract.self, from: bytes)
        try meta.validate()
        return (meta, false)
    }

    static func load(url: URL) throws -> Cube {
        let (contract, assumed) = try readContract(for: url)
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, (properties.fileSize ?? 0) <= 48_000_000 else {
            throw Failure.invalid("LUT is missing or exceeds the 48 MB import limit.")
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var minimum = SIMD3<Float>(repeating: 0)
        var maximum = SIMD3<Float>(repeating: 1)
        var values = [SIMD4<Float>]()
        var saw1D = false
        for (index, line) in content.split(whereSeparator: \.isNewline).enumerated() {
            let clean = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            let parts = clean.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            let opcode = first.uppercased()
            if opcode == "TITLE" { continue }
            if opcode == "LUT_1D_SIZE" { saw1D = true; continue }
            if opcode == "LUT_3D_SIZE" {
                guard size == 0, parts.count == 2, let n = Int(parts[1]), n >= 2, n <= 129 else {
                    throw Failure.invalid("Invalid 3D LUT size at line \(index + 1).")
                }
                size = n
                values.reserveCapacity(n*n*n)
                continue
            }
            if opcode == "DOMAIN_MIN" || opcode == "DOMAIN_MAX" {
                guard parts.count == 4, let x = Float(parts[1]), let y = Float(parts[2]),
                      let z = Float(parts[3]), x.isFinite, y.isFinite, z.isFinite else {
                    throw Failure.invalid("Invalid domain at line \(index + 1).")
                }
                if opcode == "DOMAIN_MIN" { minimum = SIMD3(x,y,z) }
                else { maximum = SIMD3(x,y,z) }
                continue
            }
            guard size > 0, parts.count == 3,
                  let x = Float(parts[0]), let y = Float(parts[1]), let z = Float(parts[2]),
                  x.isFinite, y.isFinite, z.isFinite else {
                throw Failure.invalid("Unexpected CUBE content at line \(index + 1).")
            }
            values.append(SIMD4(x,y,z,1))
            if values.count > size*size*size { throw Failure.invalid("Excess 3D samples.") }
        }
        guard !saw1D else { throw Failure.invalid("Combined 1D+3D CUBE requires a separate OCIO shaper; not safe to guess.") }
        guard size > 0, values.count == size*size*size,
              minimum.x < maximum.x, minimum.y < maximum.y, minimum.z < maximum.z else {
            throw Failure.invalid("Incomplete CUBE or invalid domain.")
        }
        // signed-log2-v1 encodes scene-referred input into [0, 1] before
        // domain normalization. A scene-linear LUT must have been *baked on
        // that same encoded grid*; the importer cannot retrofit an sRGB LUT.
        if contract.shaper == .signedLog2 && (minimum != SIMD3<Float>(repeating: 0) || maximum != SIMD3<Float>(repeating: 1)) {
            throw Failure.invalid("signed-log2-v1 LUT must use DOMAIN_MIN 0 and DOMAIN_MAX 1.")
        }
        return Cube(size: size, values: values, domainMin: minimum,
                    domainMax: maximum, contract: contract, assumedSRGB: assumed)
    }
}

/// Owns an uploaded 3D texture; the same asset is reused until the selected
/// file or its contents change. No LUT is regenerated while dragging a slider.
final class StudioImportedLUTMetal: @unchecked Sendable {
    private let gpu: GPULiveDevice
    private let kernel: any MTLComputePipelineState
    private var cached: (key: String, cube: StudioImportedLUT.Cube, texture: any MTLTexture)?
    private(set) var lutUploadCount = 0
    private(set) var lutCacheHitCount = 0

    init(gpu: GPULiveDevice) throws {
        self.gpu = gpu
        let library = try gpu.device.makeLibrary(source: Self.source, options: nil)
        guard let fn = library.makeFunction(name: "studioImportedLUTApply") else {
            throw StudioImportedLUT.Failure.invalid("Metal LUT shader missing.")
        }
        kernel = try gpu.device.makeComputePipelineState(function: fn)
    }

    func encode(source: any MTLBuffer, destination: any MTLBuffer,
                width: Int, height: Int, on command: any MTLCommandBuffer,
                file: URL) throws -> StudioImportedLUT.OutputSpace {
        let fileInfo = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let sidecar = URL(fileURLWithPath: file.path + ".lut.json")
        let sideInfo = try? sidecar.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(file.standardizedFileURL.path)|\(fileInfo.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(fileInfo.fileSize ?? 0)|\(sideInfo?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(sideInfo?.fileSize ?? 0)"
        let reused = cached?.key == stamp
        if !reused {
            let cube = try StudioImportedLUT.load(url: file)
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba32Float
            descriptor.width = cube.size
            descriptor.height = cube.size
            descriptor.depth = cube.size
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead]
            guard let texture = gpu.device.makeTexture(descriptor: descriptor),
                  let staging = cube.values.withUnsafeBytes({ bytes in
                      gpu.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count,
                                            options: .storageModeShared)
                  }),
                  let blit = command.makeBlitCommandEncoder() else {
                throw StudioImportedLUT.Failure.invalid("GPU LUT upload failed.")
            }
            let n = cube.size
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: n*16,
                      sourceBytesPerImage: n*n*16,
                      sourceSize: MTLSize(width:n,height:n,depth:n),
                      to: texture, destinationSlice:0, destinationLevel:0,
                      destinationOrigin: MTLOrigin(x:0,y:0,z:0))
            blit.endEncoding()
            // Upload and lookup share one command buffer and preserve strict
            // GPU ordering even during the first live frame; retain staging
            // until that command buffer finishes. No extra GPU fence required.
            command.addCompletedHandler { _ in withExtendedLifetime(staging) {} }
            cached = (stamp,cube,texture)
            lutUploadCount += 1
        }
        guard let entry = cached else { throw StudioImportedLUT.Failure.invalid("No uploaded LUT.") }
        if reused { lutCacheHitCount += 1 }
        let count = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !count.overflow,
              count.partialValue <= Int.max/16,
              source.length >= count.partialValue*16,
              destination.length >= count.partialValue*16 else {
            throw StudioImportedLUT.Failure.invalid("LUT source/destination buffer dimensions disagree.")
        }
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw StudioImportedLUT.Failure.invalid("Metal LUT encoder failed.")
        }
        var dims = SIMD2<UInt32>(UInt32(width),UInt32(height))
        var inputMode: UInt32 = entry.cube.contract.input == .encodedSRGB ? 0 : 1
        var shaperMode: UInt32 = entry.cube.contract.shaper == .signedLog2 ? 1 : 0
        var boundsMin = entry.cube.domainMin
        var boundsMax = entry.cube.domainMax
        encoder.setComputePipelineState(kernel)
        encoder.setBuffer(source, offset:0, index:0)
        encoder.setBuffer(destination, offset:0, index:1)
        encoder.setTexture(entry.texture, index:0)
        encoder.setBytes(&dims, length:MemoryLayout<SIMD2<UInt32>>.stride, index:2)
        encoder.setBytes(&inputMode, length:MemoryLayout<UInt32>.stride, index:3)
        encoder.setBytes(&shaperMode, length:MemoryLayout<UInt32>.stride, index:4)
        encoder.setBytes(&boundsMin, length:MemoryLayout<SIMD3<Float>>.stride, index:5)
        encoder.setBytes(&boundsMax, length:MemoryLayout<SIMD3<Float>>.stride, index:6)
        encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),
                                threadsPerThreadgroup: MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding()
        return entry.cube.contract.output
    }

    private static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    inline float signedLog(float x) {
        if (x < 0) return 0.2f*(1.f-log2(1.f+min(-x,2.f)*8.f)/log2(17.f));
        return 0.2f+0.8f*log2(1.f+min(x,64.f)*8.f)/log2(513.f);
    }
    inline float encodedSRGB(float x) {
        x = max(x, 0.f);
        return x <= 0.0031308f ? x*12.92f : 1.055f*pow(x, 1.f/2.4f)-0.055f;
    }
    inline float3 rec2020ToSRGB(float3 x) {
        float3 lin = float3(
            dot(x,float3(1.660227f,-0.587547f,-0.072839f)),
            dot(x,float3(-0.124554f,1.132926f,-0.008349f)),
            dot(x,float3(-0.018155f,-0.100603f,1.118998f)));
        return float3(encodedSRGB(lin.r),encodedSRGB(lin.g),encodedSRGB(lin.b));
    }
    inline float3 tetra(texture3d<float,access::read> lut,float3 v) {
        uint n=lut.get_width();
        float3 q=clamp(v,0.f,1.f)*float(n-1);
        uint3 lo=uint3(floor(q));
        float3 f=q-float3(lo);
        uint3 a,b;
        if (f.x>=f.y) {
            if (f.y>=f.z) { a=uint3(1,0,0);b=uint3(1,1,0); }
            else if (f.x>=f.z) { a=uint3(1,0,0);b=uint3(1,0,1); }
            else { a=uint3(0,0,1);b=uint3(1,0,1); }
        } else {
            if (f.x>=f.z) { a=uint3(0,1,0);b=uint3(1,1,0); }
            else if (f.y>=f.z) { a=uint3(0,1,0);b=uint3(0,1,1); }
            else { a=uint3(0,0,1);b=uint3(0,1,1); }
        }
        float h=f[a.x?0:(a.y?1:2)];
        uint3 step=b-a;
        float m=f[step.x?0:(step.y?1:2)];
        float l=f.x+f.y+f.z-h-m;
        float3 c0=lut.read(lo).rgb;
        float3 c1=lut.read(min(lo+a,uint3(n-1))).rgb;
        float3 c2=lut.read(min(lo+b,uint3(n-1))).rgb;
        float3 c3=lut.read(min(lo+uint3(1),uint3(n-1))).rgb;
        return c0+h*(c1-c0)+m*(c2-c1)+l*(c3-c2);
    }
    kernel void studioImportedLUTApply(device const float4* src [[buffer(0)]],
                                       device float4* dst [[buffer(1)]],
                                       texture3d<float,access::read> lut [[texture(0)]],
                                       constant uint2& dims [[buffer(2)]],
                                       constant uint& inputMode [[buffer(3)]],
                                       constant uint& shaperMode [[buffer(4)]],
                                       constant float3& domainMin [[buffer(5)]],
                                       constant float3& domainMax [[buffer(6)]],
                                       uint2 xy [[thread_position_in_grid]]) {
        if (xy.x>=dims.x || xy.y>=dims.y) return;
        uint index=xy.y*dims.x+xy.x;
        float4 x=src[index];
        float3 v;
        if (inputMode==0) v=rec2020ToSRGB(x.rgb);
        else if (shaperMode==1) v=float3(signedLog(x.r),signedLog(x.g),signedLog(x.b));
        else v=x.rgb;
        v=(v-domainMin)/(domainMax-domainMin);
        dst[index]=float4(tetra(lut,v),x.a);
    }
    """#
}


/// The settled-preview and export paths still use CPU-backed PixelBufferF32.
/// Bridge only their film stage through the *same Metal LUT shader*, then read
/// back once for the unported downstream masks/geometry/writer. Neither path
/// re-runs the native film+print simulator in imported LUT mode.
actor StudioImportedLUTOffline {
    static let shared = StudioImportedLUTOffline()
    private var gpu: GPULiveDevice?
    private var stage: StudioImportedLUTMetal?

    func gpuCacheCounts() -> (uploads: Int, hits: Int) {
        (stage?.lutUploadCount ?? 0, stage?.lutCacheHitCount ?? 0)
    }

    func render(_ input: PixelBufferF32, file: URL) async throws -> PixelBufferF32 {
        try Task.checkCancellation()
        if gpu == nil {
            guard let device = StudioGPUDevice.shared else {
                throw StudioImportedLUT.Failure.invalid("No supported Metal GPU.")
            }
            gpu = try GPULiveDevice(device: device)
        }
        guard let gpu else { throw StudioImportedLUT.Failure.invalid("Metal device unavailable.") }
        if stage == nil { stage = try StudioImportedLUTMetal(gpu: gpu) }
        guard let stage else { throw StudioImportedLUT.Failure.invalid("LUT stage unavailable.") }
        let byteCount = input.pixels.count * MemoryLayout<Float>.stride
        guard input.width > 0, input.height > 0,
              input.pixels.count == input.width * input.height * 4,
              let source = input.pixels.withUnsafeBytes({ bytes in
                  gpu.device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount,
                                        options: .storageModeShared)
              }),
              let destination = gpu.device.makeBuffer(length: byteCount,options: .storageModeShared),
              let command = gpu.queue.makeCommandBuffer() else {
            throw StudioImportedLUT.Failure.invalid("Film LUT export buffer allocation failed.")
        }
        _ = try stage.encode(source: source, destination: destination,
                             width: input.width, height: input.height,
                             on: command, file: file)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            command.addCompletedHandler { completed in
                withExtendedLifetime((source,destination)) {
                    if completed.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: StudioImportedLUT.Failure.invalid(
                        completed.error?.localizedDescription ?? "GPU LUT processing failed.")) }
                }
            }
            command.commit()
        }
        try Task.checkCancellation()
        var output = [Float](repeating: 0,count:input.pixels.count)
        output.withUnsafeMutableBytes { bytes in
            bytes.baseAddress!.copyMemory(from: destination.contents(), byteCount: byteCount)
        }
        return PixelBufferF32(width:input.width,height:input.height,pixels:output)
    }
}
