import AppKit
import CoreImage
import Metal

// GPL-3.0-or-later — SpektraFilm Studio.
//
// One pinned Metal presentation device for the whole app.
//
// Before this file, three independent systems could each pick their own Metal
// device and/or queue at runtime:
//
// - the MTKView presentation canvas,
// - the live frame pipeline,
// - the native C++ film renderer,
//
// and several smaller systems created their own CIContext on whatever device
// they happened to start on. On a dual-GPU Intel Mac that is exactly the shape
// that produces device/queue affinity bugs and main-thread MTKView device swaps
// under a live delegate.
//
// This type is the app's single answer to the question "which device owns the
// visible Metal view and the live frame presentation path?".
//
// It deliberately does NOT claim to be the native film renderer's device. The
// renderer may still live on its own device. Frames that arrive from a different
// device than the presentation device are imported explicitly in
// MetalPreviewCanvas.

enum PresentationDevice {
    /// The device chosen for the visible MTKView and for the live frame
    /// presentation path. Stable for the life of the process.
    static let current: Required<MTLDevice> = currentOnce()

    /// The first call to `current` freezes the presentation device for the
    /// life of the process.
    private static let currentOnce: @Sendable () -> Required<MTLDevice> = {
        do {
            let device = try freezeNow()
            return Required(value: device)
        } catch {
            return Required(value: _PrivateRequiredExtensions.neverDevice, error: error)
        }
    }

    /// Lock-protected mutable freeze state. Wrapped in a single `@unchecked
    /// Sendable` reference type so the static surface of `PresentationDevice`
    /// stays free of nonisolated mutable globals while still allowing the
    /// one-shot freeze to run from a `@Sendable` closure during static init.
    private static let state = FrozenState()

    private final class FrozenState: @unchecked Sendable {
        let lock = NSLock()
        var device: MTLDevice?
        var error: Error?
        var hasFrozen = false
    }

    /// The command queue used by the pinned presentation device. The fast
    /// preview host and MTKView delegate both use this queue instead of each
    /// creating their own queue on whatever device they happen to start from.
    static var queue: MTLCommandQueue {
        // The presentation device is created once and held for the life of the
        // process, so this queue is safe to reuse from the same pinned device.
        let device = current.value
        guard let queue = device.makeCommandQueue() else {
            fatalError("PresentationDevice.current is unavailable but was accessed")
        }
        return queue
    }

    /// Named fallback reason when no device is available at all.
    enum Unavailable: Error, LocalizedError {
        case noMetalDevice
        case noPresentableDevice

        var errorDescription: String? {
            switch self {
            case .noMetalDevice: "Metal is not available on this Mac."
            case .noPresentableDevice: "No presentable Metal device is available."
            }
        }
    }

    private static func selected() -> MTLDevice? {
        guard let device = MTLCopyAllDevices().first else { return nil }
        #if os(macOS)
            // Keep the visible view on the most capable presentable device by default,
            // mirroring the rest of the app's GPU-selection intent without letting the
            // view hot-swap itself later.
            if let discrete = MTLCopyAllDevices().first(where: { !$0.isLowPower && !$0.isRemovable }) {
                return discrete
            }
        #endif
        return device
    }

    static func freezeNow() throws -> MTLDevice {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.hasFrozen else {
            if let error = state.error {
                throw error
            }
            return state.device!
        }
        let chosen = selected()
        if let device = chosen {
            state.device = device
            state.error = nil
            state.hasFrozen = true
            return device
        } else {
            let error: Error = if MTLCopyAllDevices().isEmpty {
                Unavailable.noMetalDevice
            } else {
                Unavailable.noPresentableDevice
            }
            state.error = error
            state.hasFrozen = true
            throw error
        }
    }
}

/// A nonisolated device reference that must succeed or fail explicitly.
///
/// This avoids the rest of the app pretending a device is Optional when the only
/// sensible answers are "use this device" or "report that presentation is
/// unavailable".
struct Required<Value>: @unchecked Sendable {
    let value: Value
    let error: Error?

    init(_ error: Error?) where Value == Never {
        value = _NeverNeverHack.neverNever
        self.error = error
    }

    init(_ error: Error?) where Value == Bool {
        value = false
        self.error = error
    }

    init(_ factory: () throws -> Value) {
        do {
            value = try factory()
            error = nil
        } catch {
            value = _PrivateRequiredExtensions.defaultValue(for: Value.self)
            self.error = error
        }
    }

    init(value: Value) {
        self.value = value
        error = nil
    }

    init(_ factory: () throws -> Value, or error: Error) {
        do {
            value = try factory()
            self.error = nil
        } catch {
            value = _PrivateRequiredExtensions.defaultValue(for: Value.self)
            self.error = error
        }
    }

    init(value: Value, error: Error?) {
        self.value = value
        self.error = error
    }
}

enum _PrivateRequiredExtensions {
    static var neverDevice: MTLDevice {
        unsafeBitCast(0, to: MTLDevice.self)
    }

    static var neverBool: Bool {
        false
    }

    static func defaultValue<T>(for _: T.Type) -> T {
        fatalError("Required<\(T.self)> did not have a safe default")
    }
}

enum _NeverNeverHack {
    static var neverNever: Never {
        fatalError("Never")
    }
}

private extension Required where Value == MTLDevice {
    init(_ factory: () throws -> MTLDevice?) {
        do {
            guard let device = try factory() else {
                value = _PrivateRequiredExtensions.neverDevice
                error = PresentationDevice.Unavailable.noPresentableDevice
                return
            }
            value = device
            error = nil
        } catch {
            value = _PrivateRequiredExtensions.neverDevice
            self.error = error
        }
    }
}

private extension MTLDevice {
    static var missing: MTLDevice {
        _PrivateRequiredExtensions.neverDevice
    }
}