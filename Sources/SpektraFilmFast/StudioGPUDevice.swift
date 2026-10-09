import Metal
import CoreML

/// Keep image stages on the same capable GPU, including dual-GPU Intel Macs.
enum StudioGPUDevice {
    static let shared: MTLDevice? = {
        #if os(macOS)
        return MTLCopyAllDevices().first(where: { !$0.isLowPower && !$0.isRemovable }) ?? MTLCreateSystemDefaultDevice()
        #else
        return MTLCreateSystemDefaultDevice()
        #endif
    }()
    static func modelConfiguration(forSAM2: Bool = false) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        // Radeon Pro 555X produces non-finite SAM2 embeddings on macOS 15.7.9.
        // The same exact model passes on the paired Intel UHD 630 GPU.
        // This is GPU device selection, never a CPU-only inference retry.
        if forSAM2, shared?.name.contains("555X") == true,
           let integrated = MTLCopyAllDevices().first(where: { $0.isLowPower }) {
            configuration.preferredMetalDevice = integrated
        } else { configuration.preferredMetalDevice = shared }
        configuration.allowLowPrecisionAccumulationOnGPU = false
        return configuration
    }
}
