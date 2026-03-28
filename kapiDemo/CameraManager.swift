//
//  CameraManager.swift
//  kapiDemo
//

import AVFoundation
import UIKit

class CameraManager: NSObject {

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private(set) var isProRAWSupported = false

    private var captureCompletion: ((Result<Void, Error>) -> Void)?

    // MARK: - Configure

    func configure(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo // AVCaptureSessionPresetPhoto

            // Add back camera input
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                completion(false)
                return
            }
            self.session.addInput(input)

            // Add photo output
            guard self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                completion(false)
                return
            }
            self.session.addOutput(self.photoOutput)

            // Enable ProRAW if supported
            if #available(iOS 14.3, *) {
                if self.photoOutput.isAppleProRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                    self.isProRAWSupported = true
                }
            }

            self.session.commitConfiguration()
            self.session.startRunning()
            completion(true)
        }
    }

    // MARK: - Preview

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        return AVCaptureVideoPreviewLayer(session: session)
    }

    // MARK: - Capture

    func capturePhoto(completion: @escaping (Result<Void, Error>) -> Void) {
        self.captureCompletion = completion

        let settings: AVCapturePhotoSettings

        if #available(iOS 14.3, *), isProRAWSupported {
            // ProRAW capture: use RAW pixel format
            guard let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else {
                completion(.failure(CameraError.noRAWFormat))
                return
            }
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc]
            )
        } else {
            settings = AVCapturePhotoSettings()
        }

        settings.flashMode = .auto
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            captureCompletion?(.failure(error))
            captureCompletion = nil
            return
        }

        // Extract image data
        let imageData: Data?
        let isRAW: Bool

        if #available(iOS 14.3, *), photo.isRawPhoto {
            imageData = photo.fileDataRepresentation()
            isRAW = true
        } else {
            imageData = photo.fileDataRepresentation()
            isRAW = false
        }

        guard let data = imageData else {
            captureCompletion?(.failure(CameraError.noImageData))
            captureCompletion = nil
            return
        }

        // Get orientation from photo metadata
        let cgOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32
        let orientation = cgOrientation.flatMap { CGImagePropertyOrientation(rawValue: $0) }
            ?? .right // Default to .right for portrait photos

        // Process and save
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let processedImage = try ImageProcessor.processImage(data: data, isRAW: isRAW, orientation: orientation)
                PhotoSaver.save(image: processedImage) { result in
                    self?.captureCompletion?(result)
                    self?.captureCompletion = nil
                }
            } catch {
                self?.captureCompletion?(.failure(error))
                self?.captureCompletion = nil
            }
        }
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case noRAWFormat
    case noImageData

    var errorDescription: String? {
        switch self {
        case .noRAWFormat: return "No RAW format available."
        case .noImageData: return "Failed to get image data."
        }
    }
}
