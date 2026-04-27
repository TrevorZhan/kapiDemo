//
//  ImageProcessor.swift
//  kapiDemo
//

import CoreImage
import UIKit

enum ImageProcessor {

    // MARK: - Cached LUT filter (created once, reused per frame)

    private static var _cachedFilter: CIFilter?

    /// Returns a pre-configured LUT filter. Only the inputImage needs to be set per use.
    static func cachedLUTFilter() -> CIFilter? {
        if let filter = _cachedFilter { return filter }
        guard let params = try? loadCubeFile(),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            return nil
        }
        filter.setValue(params.0, forKey: "inputCubeDimension")
        filter.setValue(params.1, forKey: "inputCubeData")
        filter.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")
        _cachedFilter = filter
        return filter
    }

    /// Applies the cached LUT to a CIImage. Used by the capture pipeline.
    static func applyCachedLUT(to image: CIImage) -> CIImage? {
        guard let filter = cachedLUTFilter() else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    /// Creates a new independent LUT filter instance. Use this for threads that
    /// need their own filter (e.g. the real-time preview) to avoid contention.
    static func createLUTFilter() -> CIFilter? {
        guard let params = try? loadCubeFile(),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            return nil
        }
        filter.setValue(params.0, forKey: "inputCubeDimension")
        filter.setValue(params.1, forKey: "inputCubeData")
        filter.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")
        return filter
    }

    // MARK: - Process captured image data — deferred-delivery placeholder

    /// Fast path for the deferred-delivery placeholder. Decodes the source at a
    /// fraction of full resolution (already in display orientation), applies
    /// the LUT, then upscales the result to the source's full *display*
    /// dimensions before encoding as a low-quality JPEG with a `.up`
    /// orientation tag.
    ///
    /// Why upright pixels with `.up`:
    ///   - `PHContentEditingOutput` rejects renders larger than the asset's
    ///     recorded dimensions with PHPhotosError 3302, so we must write at
    ///     full-res — just blurry, not small.
    ///   - Empirically, Photos also rejects edits when the asset's underlying
    ///     resource has a non-`.up` orientation tag (even when pixel geometry
    ///     matches an echo of the same bytes). Both placeholder and upgrade
    ///     therefore commit to upright display pixels with `.up`.
    static func processPlaceholder(data: Data, isRAW: Bool, metadata: [String: Any]) throws -> Data {
        let decoded: CIImage
        let targetSize: CGSize

        if isRAW {
            if #available(iOS 15.0, *) {
                guard let smallFilter = CIRAWFilter(imageData: data, identifierHint: nil) else {
                    throw ProcessorError.rawDecodeFailed
                }
                smallFilter.scaleFactor = 0.25
                guard let small = smallFilter.outputImage else {
                    throw ProcessorError.rawDecodeFailed
                }
                decoded = small
                // CIRAWFilter outputs in display orientation. Quarter-res × 4 = full.
                targetSize = CGSize(width: small.extent.width * 4, height: small.extent.height * 4)
            } else {
                decoded = try decodeRAW(data: data)
                targetSize = decoded.extent.size
            }
        } else {
            // Read source pixel dims + orientation, derive display dims.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelW = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let pixelH = props[kCGImagePropertyPixelHeight] as? CGFloat else {
                throw ProcessorError.decodeFailed
            }
            let orient = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
            // Orientations 5-8 rotate by 90°/270° → display dims swap WxH.
            let rotated = (5...8).contains(orient)
            targetSize = rotated ? CGSize(width: pixelH, height: pixelW)
                                 : CGSize(width: pixelW, height: pixelH)

            // Thumbnail WITH EXIF transform → small upright pixels in display
            // orientation, matching what the final `processImage` will produce.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                throw ProcessorError.decodeFailed
            }
            decoded = CIImage(cgImage: cg)
        }

        let styled = try applyLUT(to: decoded)

        // Bilinear upscale to full display dims via affine transform.
        let scaleX = targetSize.width / styled.extent.width
        let scaleY = targetSize.height / styled.extent.height
        let upscaled = styled.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = renderContext.createCGImage(
            upscaled,
            from: CGRect(origin: .zero, size: targetSize)
        ) else {
            throw ProcessorError.renderFailed
        }

        return try renderJPEGData(
            cgImage: cgImage,
            metadata: metadata,
            orientation: .up,
            quality: 0.4
        )
    }

    // MARK: - Process captured image data

    /// Processes the image and returns JPEG Data with original EXIF metadata
    /// preserved. Output is always upright pixels with a `.up` orientation tag
    /// — the deferred-delivery upgrade requires this so the placeholder swap
    /// isn't rejected by Photos with PHPhotosError 3302.
    static func processImage(data: Data, isRAW: Bool, metadata: [String: Any], quality: CGFloat = 1.0) throws -> Data {
        let decoded: CIImage

        if isRAW {
            decoded = try decodeRAW(data: data)
        } else {
            guard let ciImage = CIImage(data: data) else {
                throw ProcessorError.decodeFailed
            }
            // Apply the EXIF orientation to the pixels so we can encode `.up`.
            let orient = (ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .right
            decoded = ciImage.oriented(orient)
        }

        let styled = try applyLUT(to: decoded)

        guard let cgImage = renderContext.createCGImage(styled, from: styled.extent) else {
            throw ProcessorError.renderFailed
        }

        return try renderJPEGData(cgImage: cgImage, metadata: metadata, orientation: .up, quality: quality)
    }

    // MARK: - Decode RAW using CIRAWFilter

    private static func decodeRAW(data: Data) throws -> CIImage {
        if #available(iOS 15.0, *) {
            guard let rawFilter = CIRAWFilter(imageData: data, identifierHint: nil) else {
                throw ProcessorError.rawDecodeFailed
            }
            guard let outputImage = rawFilter.outputImage else {
                throw ProcessorError.rawDecodeFailed
            }
            return outputImage
        } else {
            // Fallback for older iOS
            guard let ciImage = CIImage(data: data) else {
                throw ProcessorError.rawDecodeFailed
            }
            return ciImage
        }
    }

    // MARK: - Apply LUT (reuses cached filter)

    private static func applyLUT(to image: CIImage) throws -> CIImage {
        guard let output = applyCachedLUT(to: image) else {
            throw ProcessorError.filterApplicationFailed
        }
        return output
    }

    // MARK: - Parse .cube file

    private static func loadCubeFile() throws -> (Int, Data) {
        guard let url = Bundle.main.url(forResource: "典雅绿调", withExtension: "cube") else {
            throw ProcessorError.lutFileNotFound
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var dimension = 0
        var rgbValues: [Float] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") {
                continue
            }

            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let size = Int(parts[1]) {
                    dimension = size
                }
                continue
            }

            // Skip other metadata keywords
            if trimmed.hasPrefix("DOMAIN_MIN") || trimmed.hasPrefix("DOMAIN_MAX") {
                continue
            }

            // Parse RGB float values
            let parts = trimmed.split(separator: " ")
            if parts.count >= 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                rgbValues.append(r)
                rgbValues.append(g)
                rgbValues.append(b)
                rgbValues.append(1.0) // Alpha
            }
        }

        guard dimension > 0 else {
            throw ProcessorError.lutParseFailed
        }

        let expectedCount = dimension * dimension * dimension * 4
        guard rgbValues.count == expectedCount else {
            throw ProcessorError.lutParseFailed
        }

        let data = rgbValues.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        return (dimension, data)
    }

    // MARK: - Render CGImage → JPEG Data with EXIF

    private static let renderContext = CIContext()

    private static func renderJPEGData(
        cgImage: CGImage,
        metadata: [String: Any],
        orientation: CGImagePropertyOrientation,
        quality: CGFloat = 1.0
    ) throws -> Data {
        let jpegData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegData, "public.jpeg" as CFString, 1, nil
        ) else {
            throw ProcessorError.renderFailed
        }

        // Merge orientation + JPEG quality into the per-image properties.
        var properties = metadata
        properties[kCGImagePropertyOrientation as String] = orientation.rawValue
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw ProcessorError.renderFailed
        }

        return jpegData as Data
    }
}

// MARK: - Errors

enum ProcessorError: LocalizedError {
    case decodeFailed
    case rawDecodeFailed
    case lutFileNotFound
    case lutParseFailed
    case filterCreationFailed
    case filterApplicationFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "Failed to decode image data."
        case .rawDecodeFailed: return "Failed to decode RAW image."
        case .lutFileNotFound: return "LUT file 典雅绿调.cube not found in bundle."
        case .lutParseFailed: return "Failed to parse LUT file."
        case .filterCreationFailed: return "Failed to create color cube filter."
        case .filterApplicationFailed: return "Failed to apply LUT filter."
        case .renderFailed: return "Failed to render final image."
        }
    }
}
