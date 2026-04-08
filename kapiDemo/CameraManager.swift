//
//  CameraManager.swift
//  kapiDemo
//

import AVFoundation
import CoreImage
import UIKit

enum Lens: CaseIterable {
    case ultraWide  // 0.5×
    case wide       // 1×
    case telephoto  // 2× / 3× / 5× depending on device

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide:      return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    var label: String {
        switch self {
        case .ultraWide: return "0.5×"
        case .wide:      return "1×"
        case .telephoto: return "3×"
        }
    }
}

class CameraManager: NSObject {

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataQueue = DispatchQueue(label: "camera.videodata.queue", qos: .userInitiated)
    private(set) var isProRAWSupported = false

    /// Optional live preview view that receives filtered CIImage frames.
    weak var filteredPreview: FilteredPreviewView?

    private var currentInput: AVCaptureDeviceInput?
    private(set) var availableLenses: [Lens] = []
    private(set) var currentLens: Lens = .wide

    // 48MP state
    private(set) var is48MPSupported = false
    var is48MPEnabled = false
    private let dims48MP = CMVideoDimensions(width: 8064, height: 6048)

    private var captureCompletion: ((Result<TimeInterval, Error>) -> Void)?
    private var captureStartTime: CFAbsoluteTime = 0

    // MARK: - Configure

    func configure(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo // AVCaptureSessionPresetPhoto

            // Discover available physical back lenses
            self.availableLenses = Lens.allCases.filter { lens in
                AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil
            }

            // Add default wide camera input
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                completion(false)
                return
            }
            self.session.addInput(input)
            self.currentInput = input
            self.currentLens = .wide

            // Add photo output
            guard self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                completion(false)
                return
            }
            self.session.addOutput(self.photoOutput)

            // Add video data output for filtered live preview
            self.videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
            }
            self.applyPortraitRotationToVideoDataOutput()

            // Enable ProRAW if supported
            if #available(iOS 14.3, *) {
                if self.photoOutput.isAppleProRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                    self.isProRAWSupported = true
                }
            }

            // Detect and unlock 48MP support on the wide lens
            self.updateMaxPhotoDimensionsForCurrentDevice(device: camera)

            self.session.commitConfiguration()
            self.session.startRunning()
            completion(true)
        }
    }

    // MARK: - Video Data Output Rotation

    private func applyPortraitRotationToVideoDataOutput() {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - 48MP Support

    private func updateMaxPhotoDimensionsForCurrentDevice(device: AVCaptureDevice) {
        if #available(iOS 16.0, *) {
            // 48MP is only available on the wide lens of Pro models
            let supports48 = device.activeFormat.supportedMaxPhotoDimensions.contains { dims in
                dims.width >= dims48MP.width && dims.height >= dims48MP.height
            }
            is48MPSupported = supports48 && currentLens == .wide

            if supports48 {
                // Unlock the max dimensions on the output so settings can request it
                photoOutput.maxPhotoDimensions = dims48MP
            } else {
                // Reset to default (12MP) when lens doesn't support 48MP
                if let defaultDims = device.activeFormat.supportedMaxPhotoDimensions.first {
                    photoOutput.maxPhotoDimensions = defaultDims
                }
            }
        } else {
            is48MPSupported = false
        }

        // Disable 48MP if the current lens no longer supports it
        if !is48MPSupported {
            is48MPEnabled = false
        }
    }

    // MARK: - Lens Switching

    func switchLens(to lens: Lens, completion: ((Bool) -> Void)? = nil) {
        guard lens != currentLens else {
            completion?(true)
            return
        }
        guard availableLenses.contains(lens) else {
            completion?(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let newDevice = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            self.session.beginConfiguration()

            if let existing = self.currentInput {
                self.session.removeInput(existing)
            }

            guard self.session.canAddInput(newInput) else {
                // Rollback
                if let existing = self.currentInput {
                    self.session.addInput(existing)
                }
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion?(false) }
                return
            }
            self.session.addInput(newInput)
            self.currentInput = newInput
            self.currentLens = lens

            // Re-apply ProRAW setting — the photoOutput can lose it on some reconfigurations
            if #available(iOS 14.3, *), self.photoOutput.isAppleProRAWSupported {
                self.photoOutput.isAppleProRAWEnabled = true
            }

            // Re-evaluate 48MP support for the new lens
            self.updateMaxPhotoDimensionsForCurrentDevice(device: newDevice)

            // Re-apply portrait rotation — swapping the input creates a new connection
            self.applyPortraitRotationToVideoDataOutput()

            self.session.commitConfiguration()
            DispatchQueue.main.async { completion?(true) }
        }
    }

    // MARK: - Capture

    func capturePhoto(completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        self.captureCompletion = completion
        self.captureStartTime = CFAbsoluteTimeGetCurrent()

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

        // Request 48MP if enabled and supported
        if #available(iOS 16.0, *), is48MPEnabled && is48MPSupported {
            settings.maxPhotoDimensions = dims48MP
        }

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

        if #available(iOS 14.3, *) {
            if photo.isRawPhoto {
                imageData = photo.fileDataRepresentation()
                isRAW = true
            } else if isProRAWSupported {
                // This is the processed companion photo — skip it
                return
            } else {
                imageData = photo.fileDataRepresentation()
                isRAW = false
            }
        } else {
            imageData = photo.fileDataRepresentation()
            isRAW = false
        }

        guard let data = imageData else {
            captureCompletion?(.failure(CameraError.noImageData))
            captureCompletion = nil
            return
        }

        // Process and save
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let processedImage = try ImageProcessor.processImage(data: data, isRAW: isRAW)
                PhotoSaver.save(image: processedImage) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        let elapsed = CFAbsoluteTimeGetCurrent() - self.captureStartTime
                        self.captureCompletion?(.success(elapsed))
                    case .failure(let error):
                        self.captureCompletion?(.failure(error))
                    }
                    self.captureCompletion = nil
                }
            } catch {
                self.captureCompletion?(.failure(error))
                self.captureCompletion = nil
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        filteredPreview?.enqueue(ciImage)
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
