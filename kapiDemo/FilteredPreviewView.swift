//
//  FilteredPreviewView.swift
//  kapiDemo
//
//  A MTKView that renders filtered CIImage frames from the camera in real time.
//

import MetalKit
import CoreImage
import UIKit

final class FilteredPreviewView: MTKView {

    /// Set to false to bypass the LUT and render the raw camera feed.
    var isFilterEnabled: Bool = true

    private var ciContext: CIContext!
    private var commandQueue: MTLCommandQueue!
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var latestImage: CIImage?

    /// Dedicated LUT filter for the preview thread — avoids sharing with capture pipeline.
    private var previewFilter: CIFilter?

    /// Cached aspect-fill transform to avoid recomputing every frame.
    private var cachedTransform: CGAffineTransform?
    private var cachedImageSize: CGSize = .zero
    private var cachedDrawableSize: CGSize = .zero

    // MARK: - FPS / Jank tracking

    /// Rolling window of (timestamp, wasJanky) tuples, pruned to the last 1 second.
    /// Jank = the gap from the previous draw exceeded 1.5× the 60 fps target interval.
    private var drawHistory: [(time: CFAbsoluteTime, janky: Bool)] = []
    private static let targetFrameInterval: CFAbsoluteTime = 1.0 / 60.0

    /// Frames per second, computed over the last 1-second rolling window.
    private(set) var currentFPS: Double = 0
    /// Percentage of frames in the last second that arrived late (>25 ms gap).
    private(set) var jankPercent: Double = 0

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let mtlDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: mtlDevice)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if self.device == nil {
            self.device = MTLCreateSystemDefaultDevice()
        }
        commonInit()
    }

    private func commonInit() {
        guard let device = self.device else { return }
        self.commandQueue = device.makeCommandQueue()
        self.ciContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false
        ])

        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        // Use the built-in draw loop driven by display refresh
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        contentMode = .scaleAspectFill
        backgroundColor = .black

        // Build dedicated LUT filter for preview
        previewFilter = ImageProcessor.createLUTFilter()
    }

    /// Called from the camera data output delegate on a background queue.
    /// Just stores the latest frame — the MTKView draw loop renders it.
    func enqueue(_ image: CIImage) {
        latestImage = image
    }

    /// Called by the MTKView internal draw loop at preferredFramesPerSecond.
    override func draw(_ rect: CGRect) {
        guard let source = latestImage,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let filtered: CIImage
        if isFilterEnabled, let filter = previewFilter {
            filter.setValue(source, forKey: kCIInputImageKey)
            filtered = filter.outputImage ?? source
        } else {
            filtered = source
        }

        let drawableSize = drawable.layer.drawableSize
        let transform = aspectFillTransform(for: filtered.extent.size, into: drawableSize)
        let scaled = filtered.transformed(by: transform)

        ciContext.render(
            scaled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: colorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()

        updateFPSAndJank()
    }

    private func updateFPSAndJank() {
        let now = CFAbsoluteTimeGetCurrent()
        let lastTime = drawHistory.last?.time
        let janky = lastTime.map { now - $0 > Self.targetFrameInterval * 1.5 } ?? false

        // Prune entries older than 1 second and append the new one
        drawHistory.removeAll { now - $0.time > 1.0 }
        drawHistory.append((time: now, janky: janky))

        currentFPS = Double(drawHistory.count)
        let jankCount = drawHistory.filter { $0.janky }.count
        jankPercent = drawHistory.isEmpty ? 0 : Double(jankCount) / Double(drawHistory.count) * 100
    }

    /// Returns a cached affine transform that aspect-fills the image into the drawable size.
    private func aspectFillTransform(for imageSize: CGSize, into drawableSize: CGSize) -> CGAffineTransform {
        if imageSize == cachedImageSize && drawableSize == cachedDrawableSize,
           let cached = cachedTransform {
            return cached
        }

        guard imageSize.width > 0, imageSize.height > 0 else { return .identity }

        let scaleX = drawableSize.width / imageSize.width
        let scaleY = drawableSize.height / imageSize.height
        let scale = max(scaleX, scaleY)

        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale
        let dx = (scaledW - drawableSize.width) / 2
        let dy = (scaledH - drawableSize.height) / 2

        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: -dx / scale, y: -dy / scale)

        cachedTransform = transform
        cachedImageSize = imageSize
        cachedDrawableSize = drawableSize
        return transform
    }
}
