import SwiftUI
import AppKit
import CoreImage
import MetalKit

// GPL-3.0-or-later — SpektraFilm Studio.
// GPU-backed presentation surface. Keeps a stable CAMetalLayer/MTKView alive across
// slider frames; updating a preview changes GPU work, not the SwiftUI view tree.
// GPU-live frames already contain native host/film/post passes and are presented
// directly from MTLTexture; settled/exact and unsupported advanced edits retain
// the original display-image path until all remaining effects have parity.
struct MetalPreviewCanvas: NSViewRepresentable {
    let image: CGImage
    let liveFrame: GPULiveFrame?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: StudioGPUDevice.shared)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.autoResizeDrawable = true
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

        func install(view: MTKView) {
            hostView = view
            guard let device = view.device else { return }
            queue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: true,
                .useSoftwareRenderer: false
            ])
        }

        func setImage(_ image: CGImage, liveFrame: GPULiveFrame?, view: MTKView) {
            // Intel dual-GPU: the draw device must match the native film engine's
            // output device. Otherwise a Core Image texture import can fail.
            if let liveFrame,
               view.device?.registryID != liveFrame.texture.device.registryID {
                view.device = liveFrame.texture.device
                install(view: view)
            }
            let identity = ObjectIdentifier(image as AnyObject)
            lock.lock()
            let imageChanged = identity != lastImageID
            let gpuChanged = liveFrame?.id != lastGPUFrameID
            if imageChanged || gpuChanged {
                lastImageID = identity
                lastGPUFrameID = liveFrame?.id
                liveGPUFrame = liveFrame
                if imageChanged { queuedCIImage = CIImage(cgImage: image) }
                needsLatest = true
            }
            lock.unlock()
            if imageChanged || gpuChanged { view.setNeedsDisplay(view.bounds) }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Redraw the last selected image after resizing, never start a RAW decode.
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let queue, let context = ciContext else { return }
            lock.lock()
            let gpu = liveGPUFrame
            guard let image = (gpu.flatMap {
                CIImage(mtlTexture: $0.texture, options: [.colorSpace: $0.colorSpace])
            }) ?? queuedCIImage else { lock.unlock(); return }
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
            let src = image.extent
            let scale = min(CGFloat(tex.width) / max(1, src.width),
                            CGFloat(tex.height) / max(1, src.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let extent = scaled.extent
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(tex.width) - extent.width) * 0.5 - extent.minX,
                y: (CGFloat(tex.height) - extent.height) * 0.5 - extent.minY
            ))
            let canvas = CIImage(color: CIColor.black)
                .cropped(to: CGRect(x: 0, y: 0, width: tex.width, height: tex.height))
            let composition = centered.composited(over: canvas)
            context.render(
                composition, to: tex, commandBuffer: command,
                bounds: CGRect(x: 0, y: 0, width: tex.width, height: tex.height),
                colorSpace: displayColorSpace
            )
            command.present(drawable)
            command.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                self.frameCompleted()
            }
            command.commit()
        }

        private func frameCompleted() {
            lock.lock()
            inFlight = max(0, inFlight - 1)
            let redraw = needsLatest
            lock.unlock()
            if redraw {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let view = self.hostView else { return }
                    view.setNeedsDisplay(view.bounds)
                }
            }
        }
    }
}
