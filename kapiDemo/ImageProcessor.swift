//
//  ImageProcessor.swift
//  kapiDemo
//

import CoreImage
import UIKit

enum ImageProcessor {

    // MARK: - Process captured image data

    static func processImage(data: Data, isRAW: Bool) throws -> UIImage {
        // 1. Decode
        let decoded: CIImage
        if isRAW {
            decoded = try decodeRAW(data: data)
        } else {
            guard let ciImage = CIImage(data: data) else {
                throw ProcessorError.decodeFailed
            }
            decoded = ciImage
        }

        // 2. Apply LUT
        let styled = try applyLUT(to: decoded)

        // 3. Render final UIImage
        return try renderImage(styled)
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

    // MARK: - Load and apply LUT from 典雅绿调.cube

    private static func applyLUT(to image: CIImage) throws -> CIImage {
        let (dimension, cubeData) = try loadCubeFile()

        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            throw ProcessorError.filterCreationFailed
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")

        guard let output = filter.outputImage else {
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

    // MARK: - Render CIImage → UIImage

    private static func renderImage(_ ciImage: CIImage) throws -> UIImage {
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ProcessorError.renderFailed
        }
        return UIImage(cgImage: cgImage)
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
