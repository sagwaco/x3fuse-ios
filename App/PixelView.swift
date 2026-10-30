import SwiftUI
import MetalKit
import CoreImage
import os

struct PixelFrame {
    let id = UUID()
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data
}

struct PixelView: UIViewRepresentable {
    let frame: PixelFrame
    let sourceID: UUID

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Edited image preview"
        view.accessibilityHint = "Pinch to zoom, drag to pan, or double-tap to fit the image."
        let renderer = context.coordinator
        renderer.view = view
        let pinch = UIPinchGestureRecognizer(target: renderer, action: #selector(Renderer.pinch(_:)))
        pinch.delegate = renderer
        view.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: renderer, action: #selector(Renderer.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = renderer
        view.addGestureRecognizer(pan)
        let reset = UITapGestureRecognizer(target: renderer, action: #selector(Renderer.resetZoom))
        reset.numberOfTapsRequired = 2
        view.addGestureRecognizer(reset)
        view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Zoom in", target: renderer, selector: #selector(Renderer.zoomIn)),
                                           UIAccessibilityCustomAction(name: "Fit image", target: renderer, selector: #selector(Renderer.resetZoom))]
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.viewport.select(sourceID)
        guard context.coordinator.frameID != frame.id else { return }
        context.coordinator.frameID = frame.id
        context.coordinator.image = CIImage(bitmapData: frame.pixels, bytesPerRow: frame.bytesPerRow,
                                           size: CGSize(width: frame.width, height: frame.height),
                                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        view.setNeedsDisplay()
    }

    final class Renderer: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private lazy var queue = device?.makeCommandQueue()
        private lazy var context = device.map { CIContext(mtlDevice: $0) }
        var image: CIImage?
        var frameID: UUID?
        var viewport = ViewportTransform()
        weak var view: MTKView?
        private var gestureStart = ViewportTransform()
        private var pinchAnchor = CGPoint.zero

        @objc func resetZoom() -> Bool {
            viewport.reset()
            view?.setNeedsDisplay()
            return true
        }

        @objc func zoomIn() -> Bool {
            viewport.zoom = min(viewport.zoom * 2, 8)
            view?.setNeedsDisplay()
            return true
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)
            let anchor = CGPoint(x: location.x - view.bounds.midX, y: location.y - view.bounds.midY)
            if gesture.state == .began { gestureStart = viewport; pinchAnchor = anchor }
            viewport.zoom(from: gestureStart, scale: gesture.scale, startAnchor: pinchAnchor, anchor: anchor)
            view.setNeedsDisplay()
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            guard gesture.numberOfTouches == 1 else { return }
            viewport.offset = CGPoint(x: viewport.offset.x + translation.x, y: viewport.offset.y + translation.y)
            view.setNeedsDisplay()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
                || (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

        func draw(in view: MTKView) {
            guard let image, let context, let drawable = view.currentDrawable,
                  let command = queue?.makeCommandBuffer(), view.drawableSize.width > 0,
                  view.drawableSize.height > 0, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let interval = AppMetrics.signposter.beginInterval("Present")
            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            viewport.clamp(imageSize: image.extent.size, viewSize: view.bounds.size)
            let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height) * viewport.zoom
            let offset = CGPoint(x: viewport.offset.x * bounds.width / view.bounds.width,
                                 y: -viewport.offset.y * bounds.height / view.bounds.height)
            let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (bounds.width - image.extent.width * scale) / 2 + offset.x,
                                                  y: (bounds.height - image.extent.height * scale) / 2 + offset.y))
                .composited(over: CIImage(color: .black).cropped(to: bounds))
            context.render(fitted, to: drawable.texture, commandBuffer: command, bounds: bounds,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            command.present(drawable)
            command.addCompletedHandler { _ in AppMetrics.signposter.endInterval("Present", interval) }
            command.commit()
        }
    }
}

struct ViewportTransform {
    private(set) var sourceID: UUID?
    var zoom: CGFloat = 1
    var offset = CGPoint.zero

    mutating func select(_ id: UUID) {
        guard sourceID != id else { return }
        sourceID = id
        reset()
    }

    mutating func reset() { zoom = 1; offset = .zero }

    mutating func zoom(from start: ViewportTransform, scale: CGFloat, startAnchor: CGPoint, anchor: CGPoint) {
        zoom = min(max(start.zoom * scale, 1), 8)
        let ratio = zoom / start.zoom
        offset = CGPoint(x: anchor.x - (startAnchor.x - start.offset.x) * ratio,
                         y: anchor.y - (startAnchor.y - start.offset.y) * ratio)
    }

    mutating func clamp(imageSize: CGSize, viewSize: CGSize) {
        let fit = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let xLimit = max(0, (imageSize.width * fit * zoom - viewSize.width) / 2)
        let yLimit = max(0, (imageSize.height * fit * zoom - viewSize.height) / 2)
        offset.x = min(max(offset.x, -xLimit), xLimit)
        offset.y = min(max(offset.y, -yLimit), yLimit)
    }
}

enum AppMetrics {
    static let signposter = OSSignposter(subsystem: "com.sagwa.X3Fuse.native", category: "Pipeline")
}
