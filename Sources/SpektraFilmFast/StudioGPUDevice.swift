import AppKit
import CoreML
import Metal

/// Keep image stages on the same capable GPU, including dual-GPU Intel Macs.
/// Supports user selection of specific GPUs via UserDefaults.
enum StudioGPUDevice {
    /// GPU selection mode stored in UserDefaults
    enum GPUSelection: String, CaseIterable, Identifiable {
        case automatic = "Automatic"
        case discrete = "Discrete"
        case integrated = "Integrated"
        case specific = "Specific"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .automatic: return "Automatic (Recommended)"
            case .discrete: return "Discrete / External GPU"
            case .integrated: return "Integrated GPU"
            case .specific: return "Specific GPU"
            }
        }
    }

    /// Get all available Metal devices
    static var allDevices: [MTLDevice] {
        MTLCopyAllDevices()
    }

    /// Get the selected GPU based on UserDefaults preference
    static func selectedDevice() -> MTLDevice? {
        let selection =
            UserDefaults.standard.string(forKey: "StudioGPUSelection")
            .flatMap { GPUSelection(rawValue: $0) } ?? .automatic

        let devices = MTLCopyAllDevices()
        let discreteDevices = devices.filter { !$0.isLowPower && !$0.isRemovable }
        let integratedDevices = devices.filter { $0.isLowPower }

        switch selection {
        case .automatic:
            return discreteDevices.first ?? devices.first
        case .discrete:
            return discreteDevices.first ?? devices.first
        case .integrated:
            return integratedDevices.first ?? devices.first
        case .specific:
            if let gpuName = UserDefaults.standard.string(forKey: "StudioGPUSpecificName"),
                let device = devices.first(where: { $0.name == gpuName || $0.name.contains(gpuName) })
            {
                return device
            }
            return discreteDevices.first ?? devices.first
        }
    }

    /// Get the shared device (for backward compatibility)
    static var shared: MTLDevice? {
        selectedDevice()
    }

    /// Get the user's GPU selection preference
    static var currentSelection: GPUSelection {
        let selection =
            UserDefaults.standard.string(forKey: "StudioGPUSelection")
            .flatMap { GPUSelection(rawValue: $0) } ?? .automatic
        return selection
    }

    /// Set the GPU selection preference
    static func setSelection(_ selection: GPUSelection) {
        UserDefaults.standard.set(selection.rawValue, forKey: "StudioGPUSelection")
        if selection != .specific {
            UserDefaults.standard.removeObject(forKey: "StudioGPUSpecificName")
        }
        NotificationCenter.default.post(name: .gpuSelectionChanged, object: selection)
    }

    /// Get the specific GPU name if selected
    static var specificGPUName: String? {
        UserDefaults.standard.string(forKey: "StudioGPUSpecificName")
    }

    /// Set the specific GPU name
    static func setSpecificGPUName(_ name: String?) {
        if let name = name {
            UserDefaults.standard.set(name, forKey: "StudioGPUSpecificName")
        } else {
            UserDefaults.standard.removeObject(forKey: "StudioGPUSpecificName")
        }
    }

    /// Get available GPUs for the specific selection mode
    static var availableGPUs: [(name: String, isDiscrete: Bool, isRemovable: Bool)] {
        MTLCopyAllDevices().map { device in
            (name: device.name, isDiscrete: !device.isLowPower, isRemovable: device.isRemovable)
        }
    }

    static func modelConfiguration(forSAM2: Bool = false) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        // Radeon Pro 555X produces non-finite SAM2 embeddings on macOS 15.7.9.
        // The same exact model passes on the paired Intel UHD 630 GPU.
        // This is GPU device selection, never a CPU-only inference retry.
        if forSAM2, let device = selectedDevice(), device.name.contains("555X") == true,
            let integrated = MTLCopyAllDevices().first(where: { $0.isLowPower })
        {
            configuration.preferredMetalDevice = integrated
        } else {
            configuration.preferredMetalDevice = selectedDevice()
        }
        configuration.allowLowPrecisionAccumulationOnGPU = false
        return configuration
    }
}

extension Notification.Name {
    static let gpuSelectionChanged = Notification.Name("StudioGPU.gpuSelectionChanged")
}
