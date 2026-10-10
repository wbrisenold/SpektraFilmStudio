import Foundation
import CoreGraphics
import Metal
import SwiftUI
import AppKit

// GPU-only .cube playback. This stage never generates a film LUT and NEVER calls
// NativeRenderer. Host/RAW controls are upstream, lens/film effects downstream.
// Its explicit color contract is independent of SpektraFilm's legacy .sflut path.
enum StudioImportedCubeLUTSettings {
    static let folderKey = "SpektraFilmStudio.importedLUT.folder.v1"
    static let fileKey = "SpektraFilmStudio.importedLUT.file.v1"
    static let inputKey = "SpektraFilmStudio.importedLUT.input.v1"
    static let outputKey = "SpektraFilmStudio.importedLUT.output.v1"

    static var isSelected: Bool {
        // Distinct value: patch7's folder-library mode already owns "imported".
        UserDefaults.standard.string(forKey: StudioSpectralLUT.setting) == "imported-cube"
    }
    static var selectedURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: fileKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    // The .cube table coordinates may be raw linear, the signed-log shaper in
    // StudioSpectralLUT, or display-encoded sRGB after the Rec.2020 conversion.
    static var inputCode: UInt32 {
        switch UserDefaults.standard.string(forKey: inputKey) {
        case "signed-log-rec2020": return 1
        case "display-srgb": return 2
        default: return 0
        }
    }
    static var outputIsSRGB: Bool {
        UserDefaults.standard.string(forKey: outputKey) == "display-srgb"
    }
    static var colorSpace: CGColorSpace {
        if outputIsSRGB { return CGColorSpace(name: CGColorSpace.sRGB)! }
        return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    }
    static func files(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "cube" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// Parser isolated from the renderer for a predictable, once-per-file ingestion.
// The input/output color-space contract MUST be chosen in Settings; .cube
// files cannot reliably declare an input gamut or transfer function.
struct StudioCubeFile {
    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let table: [SIMD4<Float>]

    static func read(url: URL) throws -> StudioCubeFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteSize = attributes[.size] as? NSNumber, byteSize.int64Value <= 128 * 1024 * 1024 else {
            throw GPULiveError.unavailable("Cube LUT exceeds the 128 MB input limit")
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var table: [SIMD4<Float>] = []
        for (lineNumber, line) in contents.components(separatedBy: .newlines).enumerated() {
            let withoutComment = String(line.split(separator: "#", maxSplits: 1,
                                                    omittingEmptySubsequences: false).first ?? "")
            let tokens = withoutComment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let word = tokens.first else { continue }
            switch word.uppercased() {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard tokens.count == 2, let n = Int(tokens[1]), (2...129).contains(n), size == 0 else {
                    throw GPULiveError.unavailable("Invalid LUT_3D_SIZE at line \(lineNumber + 1)")
                }
                size = n
                table.reserveCapacity(n * n * n)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard tokens.count == 4,
                      let a = Float(tokens[1]), let b = Float(tokens[2]), let c = Float(tokens[3]),
                      a.isFinite, b.isFinite, c.isFinite else {
                    throw GPULiveError.unavailable("Invalid LUT domain at line \(lineNumber + 1)")
                }
                if word.uppercased() == "DOMAIN_MIN" { domainMin = SIMD3(a, b, c) }
                else { domainMax = SIMD3(a, b, c) }
            case "LUT_1D_SIZE":
                throw GPULiveError.unavailable("Combined 1D+3D .cube is not yet supported; use a 3D .cube with an explicit input shaper")
            default:
                guard size > 0, tokens.count == 3,
                      let r = Float(tokens[0]), let g = Float(tokens[1]), let b = Float(tokens[2]),
                      r.isFinite, g.isFinite, b.isFinite else {
                    throw GPULiveError.unavailable("Unsupported .cube directive/sample at line \(lineNumber + 1): \(word)")
                }
                table.append(SIMD4(r, g, b, 1))
                guard table.count <= size * size * size else {
                    throw GPULiveError.unavailable("Too many .cube samples")
                }
            }
        }
        guard size > 0, table.count == size * size * size,
              domainMax.x > domainMin.x, domainMax.y > domainMin.y,
              domainMax.z > domainMin.z else {
            throw GPULiveError.unavailable("Incomplete cube or invalid domain: expected LUT_3D_SIZE³ samples")
        }
        return StudioCubeFile(size: size, domainMin: domainMin, domainMax: domainMax, table: table)
    }
}

final class StudioImportedCubeLUT {
    private struct Cached {
        let path: String
        let fileBytes: Int64
        let modified: Date
        let texture: any MTLTexture
        let size: Int
        let domainMin: SIMD3<Float>
        let domainMax: SIMD3<Float>
    }
    private let gpu: GPULiveDevice
    private let pipeline: any MTLComputePipelineState
    private var cached: Cached?
    private(set) var diskLoads = 0

    init(gpu: GPULiveDevice) throws {
        self.gpu = gpu
        let library = try gpu.device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "studioImportedCubeKernel") else {
            throw GPULiveError.unavailable("Imported .cube Metal kernel unavailable")
        }
        pipeline = try gpu.device.makeComputePipelineState(function: function)
    }

    func encode(source: any MTLBuffer, destination: any MTLBuffer,
                width: Int, height: Int) throws -> String {
        guard let url = StudioImportedCubeLUTSettings.selectedURL else {
            throw GPULiveError.unavailable("Select a .cube from Settings > General > LUT Library")
        }
        let metadata = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modified = metadata.contentModificationDate, let bytes = metadata.fileSize else {
            throw GPULiveError.unavailable("Cannot read LUT file attributes: \(url.lastPathComponent)")
        }
        if cached?.path != url.path || cached?.modified != modified || cached?.fileBytes != Int64(bytes) {
            try load(url: url, modified: modified, fileBytes: Int64(bytes))
        }
        guard let cube = cached else { throw GPULiveError.unavailable("No resident .cube") }
        let product = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !product.overflow, product.partialValue <= Int.max / 16,
              source.length >= product.partialValue * 16,
              destination.length >= product.partialValue * 16,
              width <= Int(UInt32.max), height <= Int(UInt32.max) else {
            throw GPULiveError.unavailable("Imported LUT GPU buffers do not match image size")
        }
        guard let command = gpu.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Imported LUT Metal encoder unavailable")
        }
        var dimensions = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var lo = cube.domainMin
        var hi = cube.domainMax
        var inputCode = StudioImportedCubeLUTSettings.inputCode
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setTexture(cube.texture, index: 0)
        encoder.setBytes(&dimensions, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.setBytes(&lo, length: MemoryLayout<SIMD3<Float>>.stride, index: 3)
        encoder.setBytes(&hi, length: MemoryLayout<SIMD3<Float>>.stride, index: 4)
        encoder.setBytes(&inputCode, length: MemoryLayout<UInt32>.stride, index: 5)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()  // FIFO: downstream post-film work stays on gpu.queue
        return "Imported .cube GPU · \(url.deletingPathExtension().lastPathComponent) · \(cube.size)³"
    }

    private func load(url: URL, modified: Date, fileBytes: Int64) throws {
        // Parse/upload ONLY on file selection/change; never bake LUTs in an edit.
        let cube = try StudioCubeFile.read(url: url)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.width = cube.size
        descriptor.height = cube.size
        descriptor.depth = cube.size
        descriptor.pixelFormat = .rgba32Float
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw GPULiveError.unavailable("Cannot allocate imported .cube GPU texture")
        }
        cube.table.withUnsafeBufferPointer { bytes in
            if let base = bytes.baseAddress {
                texture.replace(region: MTLRegionMake3D(0, 0, 0, cube.size, cube.size, cube.size),
                    mipmapLevel: 0, slice: 0, withBytes: base,
                    bytesPerRow: cube.size * 16, bytesPerImage: cube.size * cube.size * 16)
            }
        }
        cached = Cached(path: url.path, fileBytes: fileBytes, modified: modified,
                        texture: texture, size: cube.size,
                        domainMin: cube.domainMin, domainMax: cube.domainMax)
        diskLoads += 1
    }

    // 3D .cube samples follow R-fastest, G-next, B-slowest ordering.
    // Tetrahedral interpolation matches the project's existing Metal LUT path.
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    inline float signedLog(float x) {
        if (x < 0.0f) return 0.2f * (1.0f - log2(1.0f + min(-x, 2.0f)*8.0f) / log2(17.0f));
        return 0.2f + 0.8f*log2(1.0f + min(x, 64.0f)*8.0f) / log2(513.0f);
    }
    inline float srgbEncode(float v) {
        return v <= 0.0031308f ? 12.92f*v : 1.055f*pow(v, 1.0f/2.4f)-0.055f;
    }
    inline float3 lookupTetra(texture3d<float, access::read> lut, float3 u) {
        uint n = lut.get_width();
        float3 q = clamp(u, 0.0f, 1.0f) * float(n-1);
        uint3 lo = uint3(floor(q));
        float3 f = q - float3(lo);
        uint3 a,b;
        if (f.x >= f.y) {
            if (f.y >= f.z) { a=uint3(1,0,0); b=uint3(1,1,0); }
            else if (f.x >= f.z) { a=uint3(1,0,0); b=uint3(1,0,1); }
            else { a=uint3(0,0,1); b=uint3(1,0,1); }
        } else {
            if (f.x >= f.z) { a=uint3(0,1,0); b=uint3(1,1,0); }
            else if (f.y >= f.z) { a=uint3(0,1,0); b=uint3(0,1,1); }
            else { a=uint3(0,0,1); b=uint3(0,1,1); }
        }
        float w1 = f[a.x ? 0 : (a.y ? 1 : 2)];
        uint3 d=b-a;
        float w2 = f[d.x ? 0 : (d.y ? 1 : 2)];
        float w3 = f.x+f.y+f.z-w1-w2;
        float3 c0=lut.read(lo).rgb;
        float3 c1=lut.read(min(lo+a,uint3(n-1))).rgb;
        float3 c2=lut.read(min(lo+b,uint3(n-1))).rgb;
        float3 c3=lut.read(min(lo+uint3(1),uint3(n-1))).rgb;
        return c0+w1*(c1-c0)+w2*(c2-c1)+w3*(c3-c2);
    }
    kernel void studioImportedCubeKernel(
        device const float4 *input [[buffer(0)]],
        device float4 *output [[buffer(1)]],
        texture3d<float, access::read> lut [[texture(0)]],
        constant uint2 &shape [[buffer(2)]],
        constant float3 &domainMin [[buffer(3)]],
        constant float3 &domainMax [[buffer(4)]],
        constant uint &mode [[buffer(5)]],
        uint2 xy [[thread_position_in_grid]]) {
        if (xy.x >= shape.x || xy.y >= shape.y) return;
        uint idx=xy.y*shape.x+xy.x;
        float4 px=input[idx];
        float3 rgb=px.rgb;
        if (mode == 1) {
            rgb=float3(signedLog(rgb.r), signedLog(rgb.g), signedLog(rgb.b));
        } else if (mode == 2) {
            float3 displayLinear = float3(
                1.660491f*rgb.r - 0.587641f*rgb.g - 0.0728499f*rgb.b,
               -0.1245505f*rgb.r + 1.1328999f*rgb.g - 0.0083494f*rgb.b,
               -0.0181508f*rgb.r - 0.1005789f*rgb.g + 1.1187297f*rgb.b);
            rgb=float3(srgbEncode(displayLinear.r),srgbEncode(displayLinear.g),srgbEncode(displayLinear.b));
        }
        float3 u=(rgb-domainMin)/(domainMax-domainMin);
        output[idx]=float4(lookupTetra(lut,u),px.a);
    }
    """#
}

// Folder-based LUT picker, installed in the existing native Settings panel.
// File selection is persisted, but loading/decoding happens only on first Metal use.
struct StudioImportedLUTSettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(StudioImportedCubeLUTSettings.folderKey) private var folder = ""
    @AppStorage(StudioImportedCubeLUTSettings.fileKey) private var selectedFile = ""
    @AppStorage(StudioImportedCubeLUTSettings.inputKey) private var inputContract = "signed-log-rec2020"
    @AppStorage(StudioImportedCubeLUTSettings.outputKey) private var outputContract = "display-srgb"
    @State private var discovered: [String] = []

    var body: some View {
        Group {
            HStack(spacing: 8) {
                Text("LUT folder")
                Spacer()
                Text(folder.isEmpty ? "Not selected" : URL(fileURLWithPath: folder).lastPathComponent)
                    .lineLimit(1).foregroundStyle(.secondary)
                Button("Choose Folder…") { chooseFolder() }
            }
            Picker("Film LUT", selection: $selectedFile) {
                Text("Select a LUT").tag("")
                ForEach(discovered, id: \.self) { path in
                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                        .tag(path)
                }
            }
            Picker("LUT input", selection: $inputContract) {
                Text("Scene-linear Rec.2020 + signed-log shaper").tag("signed-log-rec2020")
                Text("Scene-linear Rec.2020, unshaped").tag("linear-rec2020")
                Text("Display sRGB").tag("display-srgb")
            }
            Picker("LUT output", selection: $outputContract) {
                Text("Display sRGB").tag("display-srgb")
                Text("Linear Rec.2020").tag("linear-rec2020")
            }
            Text("Imported LUT mode bypasses the native film engine. Set the input/output contract to match your generator; the app does not infer a gamut from an untagged .cube. Film-stock sliders baked into the LUT must be regenerated outside the live editor.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: selectedFile) { _, _ in model.rendererPolicyDidChange() }
        .onChange(of: inputContract) { _, _ in model.rendererPolicyDidChange() }
        .onChange(of: outputContract) { _, _ in model.rendererPolicyDidChange() }
    }

    private func refresh() {
        guard !folder.isEmpty else { discovered = []; return }
        discovered = StudioImportedCubeLUTSettings.files(in: URL(fileURLWithPath: folder)).map(\.path)
        if !discovered.contains(selectedFile) { selectedFile = "" }
    }

    private func chooseFolder() {
        Task { @MainActor in
            guard let url = await SpektraFilePanel.folder(title: "Use LUT Folder") else { return }
            folder = url.standardizedFileURL.path
            selectedFile = ""
            refresh()
            model.rendererPolicyDidChange()
        }
    }
}
