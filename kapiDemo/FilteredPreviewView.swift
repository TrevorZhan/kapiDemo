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
    private var currentCIImage: CIImage?
    private let renderLock = NSLock()

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
        self.ciContext = CIContext(mtlDevice: device)

        framebufferOnly = false                          // required for CIContext.render
        colorPixelFormat = .bgra8Unorm
        isPaused = true                                  // we'll manually trigger draws
        enableSetNeedsDisplay = false
        contentMode = .scaleAspectFill
        backgroundColor = .black
    }

    /// Called from the camera data output delegate on a background queue.
    func enqueue(_ image: CIImage) {
        renderLock.lock()
        currentCIImage = image
        renderLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.draw()
        }
    }

    override func draw(_ rect: CGRect) {
        renderLock.lock()
        let source = currentCIImage
        renderLock.unlock()

        guard let source = source,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Apply LUT (reuses cached cube data from ImageProcessor)
        let filtered: CIImage
        if isFilterEnabled, let styled = ImageProcessor.applyCachedLUT(to: source) {
            filtered = styled
        } else {
            filtered = source
        }

        // Aspect-fill scale + center into the drawable
        let drawableSize = drawable.layer.drawableSize
        let scaled = aspectFill(filtered, into: drawableSize)

        ciContext.render(
            scaled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: colorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Scales and translates a CIImage so it aspect-fills the given drawable size.
    private func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let imageSize = image.extent.size
        guard imageSize.width > 0, imageSize.height > 0 else { return image }

        let scaleX = size.width / imageSize.width
        let scaleY = size.height / imageSize.height
        let scale = max(scaleX, scaleY)

        var transformed = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        // Center crop
        let scaledExtent = transformed.extent
        let dx = (scaledExtent.width - size.width) / 2
        let dy = (scaledExtent.height - size.height) / 2
        transformed = transformed.transformed(
            by: CGAffineTransform(translationX: -scaledExtent.origin.x - dx,
                                  y: -scaledExtent.origin.y - dy)
        )
        return transformed
    }
}
