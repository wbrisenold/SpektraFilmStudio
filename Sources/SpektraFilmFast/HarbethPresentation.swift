import CoreGraphics
import Foundation // for UInt8
import Metal
import MetalKit

// GPL-3.0-or-later — SpektraFilm Studio.
//
// Local fast preview/display/conversion host adapter.
//
// This is the boundary layer between SpektraFilm's pinned Metal presentation
// device and the app's fast preview/display hosting concept. It does NOT import
// Harbeth's film-processing or spectral-rendering responsibilities. The exact
// spectral film renderer remains the app's authoritative render core for
// committed previews and export.
//
// Harbeth is the external reference for this shape: a render core produces a
// texture/frame and a separate host view displays it. This file is SpektraFilm's
// host adapter, not a full Harbeth pipeline import. It is named for that external
// boundary concept only.
//
// This module is SpektraFilm's surface-defined fast preview/display/conversion host
// boundary. Its public surface is the `PublicPresentationHost` namespace, not any
// single struct type. Callers reach `PublicPresentationHost.makeView`,
// `PublicPresentationHost.commandQueue`, `PublicPresentationHost.device`, and
// `PublicPresentationHost.displayFrame(from:colorSpace:into:)` through that
// namespace, and the rest of the app treats the host boundary as one pinned Metal
// presentation concept.

// MARK: - Harbeth host boundary module root

/// SpektraFilm's local fast preview / display / conversion host-boundary module.
///
/// This enum is only the module root of the Harbeth host boundary. The actual public
/// surface is the `PublicPresentationHost` namespace below; the enum exists so this
/// file is a coherent host-boundary module rather than a loose bag of free functions
/// and statics.
enum HarbethPresentation {}

// MARK: - Pinned Metal presentation device

private let presentationDevice = PresentationDevice.current

// MARK: - Public presentation host surface

/// Public surface of SpektraFilm's fast preview / display / conversion host boundary.
///
/// Everything outside the host boundary reaches the pinned Metal presentation device
/// and the MTKView presentation canvas through this namespace.
enum PublicPresentationHost {
    /// The MTKView the fast preview canvas hosts on.
    @MainActor
    static func makeView(frame: CGRect) -> MTKView {
        let view = MTKView(frame: frame)
        view.device = presentationDevice.value
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.colorPixelFormat = .rgba32Float
        return view
    }

    /// The pinned command queue the fast preview host uses for presentation draws.
    static var commandQueue: MTLCommandQueue {
        PresentationDevice.queue
    }

    /// The pinned presentation device underlying the fast preview host.
    static var device: any MTLDevice {
        presentationDevice.value
    } // Present a Metal frame as a CIImage that the host view can consume.
    ///
    /// - Parameters:
    ///   - texture: the Metal texture to display.
    ///   - colorSpace: the texture's working color space.
    ///   - view: the MTKView hosting the fast preview surface.
    /// - Returns: a displayable CIImage, or `nil` when the frame cannot be imported
    ///   into the host view's device.
    static func displayFrame(
        from texture: any MTLTexture,
        colorSpace: CGColorSpace,
        into _: MTKView,
    ) -> CIImage? {
        guard texture.device.registryID == presentationDevice.value.registryID else { return nil }
        return CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])
    }
}
