import AppKit
import CoreImage
import MetalKit
import SwiftUI

/// GPL-3.0-or-later — SpektraFilm Studio.
///
/// GPU-backed presentation surface for SpektraFilm's pinned presentation device.
/// The fast preview/display layer now has an adapter boundary in
/// HarbethPresentation, so the view layer here expresses itself as a host
/// adapter instead of owning raw device/queue presentation policy directly.
///
/// This file remains the local MTKView delegate and composition host. It does
/// NOT depend on Harbeth as an external package at this layer; HarbethPresentation
/// is the boundary that owns the host/conversion semantics for the fast preview
/// layer, whether or not the app later imports a Harbeth package.
struct MetalPreviewCanvas: NSViewRepresentable {
    let image: CGImage
    let liveFrame: GPULiveFrame?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = PublicPresentationHost.makeView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.install(view: view)
        context.coordinator.setImage(image, liveFrame: liveFrame, view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.setImage(image, liveFrame: liveFrame, view: nsView)
    }

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        private weak var hostView: MTKView?
        private let lock = NSLock()
        private var queuedCIImage: CIImage?
        private var lastImageID: ObjectIdentifier?
        private var liveGPUFrame: GPULiveFrame?
        private var lastGPUFrameID: UUID?
        private var inFlight = 0
        private var needsLatest = false
        private var queue: MTLCommandQueue?
        private var ciContext: CIContext?
        private let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        /// AppKit view access (device, setNeedsDisplay, bounds) is main-actor isolated.
        /// Both methods are only invoked from makeNSView/updateNSView, which are
        /// themselves main-actor, so the annotation reflects existing call sites
        /// rather than introducing a new hop.
        @MainActor
        func install(view: MTKView) {
            hostView = view
            queue = PublicPresentationHost.commandQueue
            ciContext = CIContext(
                mtlDevice: PublicPresentationHost.device,
                options: [
                    .cacheIntermediates: true,
                    .useSoftwareRenderer: false,
                ],
            )
        }

        @MainActor
        func setImage(_ image: CGImage, liveFrame: GPULiveFrame?, view: MTKView) {
            // Keep the MTKView on one device for its life. Hot-swapping view.device
            // while the MTKViewDelegate can be drawing is a main-thread device/queue
            // race on dual-GPU Intel Macs. If a live frame arrives from a different
            // device, we still accept the frame and let draw(in:) import/convert it
            // into the view's already-installed device rather than changing the view.
            let identity = ObjectIdentifier(image as AnyObject)
            lock.lock()
            let imageChanged = identity != lastImageID
            let gpuChanged = liveFrame?.id != lastGPUFrameID
            if imageChanged || gpuChanged {
                lastImageID = identity
                lastGPUFrameID = liveFrame?.id
                liveGPUFrame = liveFrame
                if imageChanged {
                    queuedCIImage = CIImage(cgImage: image)
                }
                needsLatest = true
            }
            lock.unlock()
            if imageChanged || gpuChanged {
                view.setNeedsDisplay(view.bounds)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange _: CGSize) {
            // Redraw the last selected image after resizing, never start a RAW decode.
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let queue, let context = ciContext
            else { return }
            lock.lock()
            let gpu = liveGPUFrame
            // The view keeps one device for its life. A live frame can still arrive
            // from a different device, and a CIContext may not import a foreign
            // texture directly. When that can happen, copy the frame into the view's
            // device through a shared CPU-accessible buffer instead of presenting an
            // error frame or importing from the wrong device.
            var image: CIImage? = if let gpu {
                if gpu.texture.device.registryID == PublicPresentationHost.device.registryID {
                    (try? MetalPreviewComposition.content(texture: gpu.texture, colorSpace: gpu.colorSpace)) ?? queuedCIImage
                } else {
                    PublicPresentationHost.displayFrame(from: gpu.texture, colorSpace: gpu.colorSpace, into: view) ?? queuedCIImage
                }
            } else {
                queuedCIImage
            }
            // A requested GPU texture must NEVER silently display an older CPU
            // picture. Mark a presentation failure visibly with a red error frame.
            if gpu != nil && image == nil {
                image = CIImage(
                    color: CIColor(
                        red: 0.65, green: 0.02,
                        blue: 0.04, alpha: 1,
                    ),
                ).cropped(
                    to: CGRect(
                        x: 0, y: 0,
                        width: max(1, view.drawableSize.width),
                        height: max(1, view.drawableSize.height),
                    ),
                )
                NSLog("SPEKTRA_GPU_PRESENTATION_ERROR: Unable to import the current Metal frame")
            }
            guard let image else { lock.unlock(); return }
            if inFlight >= 2 {
                needsLatest = true
                lock.unlock()
                return
            }
            inFlight += 1
            needsLatest = false
            lock.unlock()
            guard let command = queue.makeCommandBuffer() else {
                frameCompleted()
                return
            }

            let tex = drawable.texture
            let composition = MetalPreviewComposition.letterbox(
                image,
                width: tex.width, height: tex.height,
            )
            context.render(
                composition, to: tex, commandBuffer: command,
                bounds: CGRect(x: 0, y: 0, width: tex.width, height: tex.height),
                colorSpace: displayColorSpace,
            )
            command.present(drawable)
            command.addCompletedHandler { [weak self, gpu] command in
                // MTKView may switch to a newer frame before this GPU draw
                // completes. Retain the old texture until Metal is finished.
                withExtendedLifetime(gpu) {
                    if command.status != .completed {
                        NSLog(
                            "SPEKTRA_GPU_PRESENTATION_ERROR: %@",
                            command.error?.localizedDescription ?? "GPU display failed",
                        )
                    }
                    self?.frameCompleted()
                }
            }
            command.commit()
        }

        private func importLiveFrameForView(_ texture: any MTLTexture, colorSpace: CGColorSpace, view: MTKView) -> CIImage? {
            // Kept as the local fallback importer for the pinned presentation device.
            // When the fast preview layer adopts Harbeth, this helper is the place
            // where a Harbeth-side conversion path could be swapped in without
            // changing the rest of the canvas.
            PublicPresentationHost.displayFrame(from: texture, colorSpace: colorSpace, into: view)
        }

        private func frameCompleted() {
            lock.lock()
            inFlight = max(0, inFlight - 1)
            let redraw = needsLatest
            lock.unlock()
            if redraw {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let view = hostView else { return }
                    view.setNeedsDisplay(view.bounds)
                }
            }
        }
    }
}
