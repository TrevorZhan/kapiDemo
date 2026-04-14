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

    /// Applies the cached LUT to a CIImage. Safe to call per frame.
    static func applyCachedLUT(to image: CIImage) -> CIImage? {
        guard let filter = cachedLUTFilter() else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    // MARK: - Process captured image data

    /// Processes the image and returns JPEG Data with original EXIF metadata preserved.
    static func processImage(data: Data, isRAW: Bool, metadata: [String: Any]) throws -> Data {
        // 1. Decode
        let decoded: CIImage
        let imageOrientation: CGImagePropertyOrientation

        if isRAW {
            decoded = try decodeRAW(data: data)
            imageOrientation = .up
        } else {
            guard let ciImage = CIImage(data: data) else {
                throw ProcessorError.decodeFailed
            }
            decoded = ciImage
            if let ciOriValue = decoded.properties[kCGImagePropertyOrientation as String] as? UInt32,
               let ciOri = CGImagePropertyOrientation(rawValue: ciOriValue) {
                imageOrientation = ciOri
            } else {
                imageOrientation = .right
            }
        }

        // 2. Apply LUT
        let styled = try applyLUT(to: decoded)

        // 3. Render to CGImage
        guard let cgImage = renderContext.createCGImage(styled, from: styled.extent) else {
            throw ProcessorError.renderFailed
        }

        // 4. Write JPEG with original EXIF metadata
        return try renderJPEGData(cgImage: cgImage, metadata: metadata, orientation: imageOrientation)
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
        orientation: CGImagePropertyOrientation
    ) throws -> Data {
        let jpegData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegData, "public.jpeg" as CFString, 1, nil
        ) else {
            throw ProcessorError.renderFailed
        }

        // Merge orientation into metadata
        var properties = metadata
        properties[kCGImagePropertyOrientation as String] = orientation.rawValue

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
