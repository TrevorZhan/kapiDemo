//
//  CameraManager.swift
//  kapiDemo
//

import AVFoundation
import CoreImage
import ImageIO
import UIKit

// MARK: - Capture Tracking Model

/// Lifecycle stages reported to the UI for the debug carousel.
enum CaptureStatus {
    case capturing      // shutter fired, awaiting image data from AVFoundation
    case finalizing     // image data in hand, applying LUT + saving to Photos
    case ready          // saved to Photos successfully
    case failed
}

/// One capture's worth of UI-facing state.
struct CaptureItem {
    let id: Int64
    var status: CaptureStatus
    /// Bytes of the captured image data before LUT processing.
    var placeholderSize: Int = 0
    /// Bytes of the LUT-applied JPEG. Set once processing finishes.
    var finalSize: Int?
    /// Small downsampled preview of the processed image, for the carousel.
    var thumbnail: UIImage?
}

/// Snapshot of all tracked capture state — emitted on every transition.
struct CaptureSnapshot {
    let inFlight: Int
    let maxConcurrent: Int
    let doneCount: Int
    let rejectedCount: Int
    /// Carousel items, oldest first. Includes in-flight plus recently
    /// completed entries that haven't yet aged out.
    let items: [CaptureItem]
}

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
    /// When true and ProRAW is supported, capture uses the RAW pipeline. Otherwise JPEG/HEIC.
    var useProRAW = false
    /// When true, capture produces a Live Photo (still + video pair with LUT applied).
    var isLivePhotoMode = false
    private(set) var isLivePhotoCaptureSupported = false

    /// Optional live preview view that receives filtered CIImage frames.
    weak var filteredPreview: FilteredPreviewView?

    // Per-capture state for concurrent captures
    private class CaptureContext {
        let completion: (Result<TimeInterval, Error>) -> Void
        let startTime: CFAbsoluteTime
        /// Stamped when image data is received and actual processing begins.
        /// Used to measure only the processing+saving time, independent of
        /// how long the capture sat in the burst queue before its turn.
        var processingStartTime: CFAbsoluteTime = 0
        var livePhotoRawData: Data?
        var livePhotoIsRAW: Bool = false
        var livePhotoMetadata: [String: Any]?
        var livePhotoMovieURL: URL?

        init(completion: @escaping (Result<TimeInterval, Error>) -> Void) {
            self.completion = completion
            self.startTime = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Active captures keyed by AVCapturePhotoSettings.uniqueID
    private var activeCaptures: [Int64: CaptureContext] = [:]

    /// Number of captures currently in-flight (for the performance HUD).
    var activeCapturesCount: Int { activeCaptures.count }

    // Background task — keeps the app alive long enough to finish processing
    // and saving all in-flight captures when the user exits the app mid-burst.
    private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    private var activeCaptureCount = 0

    // MARK: - UI tracking (debug HUD + thumbnail carousel)

    /// Total successful saves since the manager was created.
    private(set) var doneCount: Int = 0
    /// Number of shutter taps dropped because the photo output was saturated.
    private(set) var rejectedCount: Int = 0

    /// Carousel state: in-flight plus recently completed entries.
    /// Mutated only on the main queue so the UI can read it safely.
    private var carouselItems: [Int64: CaptureItem] = [:]
    private var carouselOrder: [Int64] = []
    private var pendingEvictions: [Int64: DispatchWorkItem] = [:]

    /// Fired on the main queue whenever any tracked capture state changes.
    var onCaptureUpdate: ((CaptureSnapshot) -> Void)?

    /// How long a completed item lingers in the carousel before fading out.
    private static let completedItemTTL: TimeInterval = 10.0

    private var audioInput: AVCaptureDeviceInput?

    // KVO token for monitoring focus adjustment completion
    private var focusObservation: NSKeyValueObservation?

    // KVO token for monitoring continuous auto-exposure changes
    private var exposureObservation: NSKeyValueObservation?
    /// Set to true while a tap-triggered exposure adjustment is in flight,
    /// so the auto-exposure indicator is suppressed for user-initiated adjustments.
    private var isTapAdjusting = false

    /// Called on the main thread whenever the camera auto-adjusts exposure
    /// without a user tap (e.g. moving from a bright area to a dark one).
    var onAutoExposureAdjust: (() -> Void)?

    private var currentInput: AVCaptureDeviceInput?
    private(set) var availableLenses: [Lens] = []
    private(set) var currentLens: Lens = .wide

    // 48MP state
    private(set) var is48MPSupported = false
    var is48MPEnabled = false
    private let dims48MP = CMVideoDimensions(width: 8064, height: 6048)

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

            // Add video data output for filtered live preview (native YUV avoids CPU conversion)
            self.videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
            }
            self.applyPortraitRotationToVideoDataOutput()

            // Configure audio session and add audio input for Live Photos
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
                try audioSession.setActive(true)
            } catch {
                print("Warning: Failed to configure audio session: \(error)")
            }

            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioIn = try? AVCaptureDeviceInput(device: audioDevice),
               self.session.canAddInput(audioIn) {
                self.session.addInput(audioIn)
                self.audioInput = audioIn
            }

            // Enable ProRAW if supported
            if #available(iOS 14.3, *) {
                if self.photoOutput.isAppleProRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                    self.isProRAWSupported = true
                }
            }

            // Enable Live Photo capture if supported
            if self.photoOutput.isLivePhotoCaptureSupported {
                self.photoOutput.isLivePhotoCaptureEnabled = true
                self.isLivePhotoCaptureSupported = true
            }

            // Detect and unlock 48MP support on the wide lens
            self.updateMaxPhotoDimensionsForCurrentDevice(device: camera)

            self.session.commitConfiguration()
            self.session.startRunning()
            self.attachExposureObserver(to: camera)
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

            // Re-enable Live Photo capture
            if self.photoOutput.isLivePhotoCaptureSupported {
                self.photoOutput.isLivePhotoCaptureEnabled = true
            }

            // Re-evaluate 48MP support for the new lens
            self.updateMaxPhotoDimensionsForCurrentDevice(device: newDevice)

            // Re-apply portrait rotation — swapping the input creates a new connection
            self.applyPortraitRotationToVideoDataOutput()

            self.session.commitConfiguration()
            self.attachExposureObserver(to: newDevice)
            DispatchQueue.main.async { completion?(true) }
        }
    }

    // MARK: - Capture

    /// Maximum number of simultaneous in-flight captures before new ones are silently dropped.
    /// Exceeding AVCapturePhotoOutput's internal capacity produces "Cannot take photo" errors.
    static let maxConcurrentCaptures = 8

    // MARK: - Performance metrics (read by the debug HUD)

    /// Milliseconds from shutter tap to image data arriving in the delegate.
    /// Updated whenever a capture's image data is received.
    private(set) var lastCaptureLatencyMs: Int = 0

    /// Milliseconds from image data arrival to Photos save completing.
    /// Updated whenever a capture finishes successfully.
    private(set) var lastPostLatencyMs: Int = 0

    /// Running total of preview frames dropped by AVCaptureVideoDataOutput
    /// because they arrived faster than the app could process them.
    private(set) var droppedFrames: Int = 0

    func capturePhoto(completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        // Silently drop taps when the photo output is saturated — avoids AVFoundation
        // capacity errors that would surface as "Cannot take photo" toasts during burst.
        guard activeCaptures.count < Self.maxConcurrentCaptures else {
            bumpRejected()
            return
        }

        let settings: AVCapturePhotoSettings
        let captureAsProRAW = useProRAW && isProRAWSupported && !isLivePhotoMode

        if #available(iOS 14.3, *), captureAsProRAW {
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

        // Live Photo: set a temp movie URL for the video portion
        if isLivePhotoMode && isLivePhotoCaptureSupported && photoOutput.isLivePhotoCaptureEnabled {
            let tempDir = FileManager.default.temporaryDirectory
            let movieURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            settings.livePhotoMovieFileURL = movieURL
            settings.livePhotoVideoCodecType = .hevc
        }

        // Register per-capture state keyed by the unique settings ID
        let context = CaptureContext(completion: completion)
        activeCaptures[settings.uniqueID] = context

        // Reflect the capture in the carousel right away so the UI shows it
        // as in-flight even before image data arrives.
        addCarouselItem(CaptureItem(id: settings.uniqueID, status: .capturing))

        // Ensure the app stays alive in the background until this capture is saved
        beginBackgroundTaskIfNeeded()

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Background Task

    /// Increments the in-flight capture count and starts a background task on first call.
    private func beginBackgroundTaskIfNeeded() {
        activeCaptureCount += 1
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "com.kapi.photoCapture") { [weak self] in
            self?.handleBackgroundTaskExpiration()
        }
    }

    /// Decrements the in-flight count and ends the background task when all captures are done.
    private func endBackgroundTaskIfDone() {
        activeCaptureCount -= 1
        guard activeCaptureCount <= 0 else { return }
        activeCaptureCount = 0
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Called by iOS when background time is nearly exhausted (~30 s window exceeded).
    /// Cleans up temp files for any still-pending captures, then yields the task.
    private func handleBackgroundTaskExpiration() {
        for (_, context) in activeCaptures {
            if let url = context.livePhotoMovieURL {
                cleanupTempFile(at: url)
            }
        }
        activeCaptures.removeAll()
        activeCaptureCount = 0
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Carousel state mutators (always on main)

    /// Inserts a new carousel entry at the end and emits a snapshot.
    private func addCarouselItem(_ item: CaptureItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.carouselItems[item.id] = item
            self.carouselOrder.append(item.id)
            self.emitSnapshotOnMain()
        }
    }

    /// Mutates an existing carousel entry and emits a snapshot.
    private func updateCarouselItem(_ id: Int64, _ mutate: @escaping (inout CaptureItem) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, var item = self.carouselItems[id] else { return }
            mutate(&item)
            self.carouselItems[id] = item
            self.emitSnapshotOnMain()
        }
    }

    /// Removes a carousel entry immediately (used to silently drop swallowed errors).
    private func removeCarouselItem(_ id: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingEvictions[id]?.cancel()
            self.pendingEvictions.removeValue(forKey: id)
            self.carouselItems.removeValue(forKey: id)
            self.carouselOrder.removeAll { $0 == id }
            self.emitSnapshotOnMain()
        }
    }

    /// Schedules a carousel entry to fade out after `completedItemTTL` seconds.
    private func scheduleCarouselEviction(_ id: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingEvictions[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.carouselItems.removeValue(forKey: id)
                self.carouselOrder.removeAll { $0 == id }
                self.pendingEvictions.removeValue(forKey: id)
                self.emitSnapshotOnMain()
            }
            self.pendingEvictions[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.completedItemTTL, execute: work)
        }
    }

    /// Bumps the rejected counter and emits a snapshot.
    private func bumpRejected() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rejectedCount += 1
            self.emitSnapshotOnMain()
        }
    }

    /// Bumps the done counter and emits a snapshot.
    private func bumpDone() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.doneCount += 1
            self.emitSnapshotOnMain()
        }
    }

    /// Builds and dispatches a snapshot. Must be called on main.
    private func emitSnapshotOnMain() {
        let items = carouselOrder.compactMap { carouselItems[$0] }
        let snapshot = CaptureSnapshot(
            inFlight: activeCaptures.count,
            maxConcurrent: Self.maxConcurrentCaptures,
            doneCount: doneCount,
            rejectedCount: rejectedCount,
            items: items
        )
        onCaptureUpdate?(snapshot)
    }

    /// Cheap thumbnail from a JPEG buffer using ImageIO's built-in downsampler.
    /// No re-decode of the full image — pixel-size-bounded thumbnail extracted from the source.
    fileprivate func makeThumbnail(from jpegData: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 220,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let captureID = photo.resolvedSettings.uniqueID
        guard let context = activeCaptures[captureID] else { return }

        if let error = error {
            activeCaptures.removeValue(forKey: captureID)
            endBackgroundTaskIfDone()
            // Swallow AVFoundation hardware/capacity errors (e.g. "Cannot take photo"
            // when the photo output is momentarily saturated during rapid burst shooting).
            // These are expected under load and not meaningful to the user.
            guard (error as NSError).domain != AVFoundationErrorDomain else {
                // Drop the carousel entry silently too — the user shouldn't see a
                // "Failed" cell for an error we deliberately suppressed.
                removeCarouselItem(captureID)
                return
            }
            updateCarouselItem(captureID) { $0.status = .failed }
            scheduleCarouselEviction(captureID)
            context.completion(.failure(error))
            return
        }

        // Extract image data
        let imageData: Data?
        let isRAW: Bool

        if #available(iOS 14.3, *) {
            if photo.isRawPhoto {
                imageData = photo.fileDataRepresentation()
                isRAW = true
            } else if useProRAW && isProRAWSupported {
                // This is the processed companion photo from a ProRAW capture — skip it
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
            activeCaptures.removeValue(forKey: captureID)
            context.completion(.failure(CameraError.noImageData))
            return
        }

        // Capture the full EXIF metadata from the photo
        let metadata = photo.metadata

        if isLivePhotoMode && isLivePhotoCaptureSupported {
            // Live Photo: store the raw data and wait for the video callback.
            // We defer image processing until the video arrives so we can
            // embed the matching content identifier into the JPEG.
            context.livePhotoRawData = data
            context.livePhotoIsRAW = isRAW
            context.livePhotoMetadata = metadata
            finalizeLivePhotoIfReady(captureID: captureID)
        } else {
            // Standard photo: process and save immediately.
            // Stamp processing start time now — after image data arrives —
            // so the reported duration measures processing+saving only,
            // not the burst queue wait before this photo's turn.
            context.processingStartTime = CFAbsoluteTimeGetCurrent()
            lastCaptureLatencyMs = Int((context.processingStartTime - context.startTime) * 1000)
            let placeholderSize = data.count
            updateCarouselItem(captureID) {
                $0.placeholderSize = placeholderSize
                $0.status = .finalizing
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let processedData = try ImageProcessor.processImage(data: data, isRAW: isRAW, metadata: metadata)
                    let thumbnail = self.makeThumbnail(from: processedData)
                    let finalSize = processedData.count
                    self.updateCarouselItem(captureID) {
                        $0.finalSize = finalSize
                        $0.thumbnail = thumbnail
                    }
                    PhotoSaver.save(imageData: processedData) { [weak self] result in
                        self?.completeCapture(captureID: captureID, result: result)
                    }
                } catch {
                    self.completeCapture(captureID: captureID, result: .failure(error))
                }
            }
        }
    }

    // MARK: - Live Photo Video Callback

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let captureID = resolvedSettings.uniqueID
        guard let context = activeCaptures[captureID] else {
            cleanupTempFile(at: outputFileURL)
            return
        }

        if let error = error {
            cleanupTempFile(at: outputFileURL)
            completeCapture(captureID: captureID, result: .failure(error))
            return
        }

        // Apply LUT to the video, then store the processed URL
        VideoProcessor.applyLUT(to: outputFileURL) { [weak self] processedURL in
            guard let self = self else { return }
            // Clean up the original unprocessed movie
            self.cleanupTempFile(at: outputFileURL)

            if let processedURL = processedURL {
                context.livePhotoMovieURL = processedURL
            } else {
                self.completeCapture(captureID: captureID, result: .failure(CameraError.livePhotoVideoProcessingFailed))
                return
            }
            self.finalizeLivePhotoIfReady(captureID: captureID)
        }
    }

    /// Called after each Live Photo piece (still + video) arrives. Saves when both are ready.
    private func finalizeLivePhotoIfReady(captureID: Int64) {
        guard let context = activeCaptures[captureID],
              let rawData = context.livePhotoRawData,
              let metadata = context.livePhotoMetadata,
              let movieURL = context.livePhotoMovieURL else {
            return // waiting for the other piece
        }

        let isRAW = context.livePhotoIsRAW

        // Stamp processing start time now that both pieces are ready and
        // actual work (content-ID read + image processing + save) begins.
        context.processingStartTime = CFAbsoluteTimeGetCurrent()
        lastCaptureLatencyMs = Int((context.processingStartTime - context.startTime) * 1000)
        let placeholderSize = rawData.count
        updateCarouselItem(captureID) {
            $0.placeholderSize = placeholderSize
            $0.status = .finalizing
        }

        Task { [weak self] in
            let contentID = await VideoProcessor.readContentIdentifier(from: movieURL)
            guard let self = self else { return }

            // Embed the content identifier into the JPEG metadata so it matches the video
            var enrichedMetadata = metadata
            if let contentID = contentID {
                var makerApple = enrichedMetadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
                makerApple["17"] = contentID
                enrichedMetadata[kCGImagePropertyMakerAppleDictionary as String] = makerApple
            }

            do {
                let processedData = try ImageProcessor.processImage(
                    data: rawData, isRAW: isRAW, metadata: enrichedMetadata
                )
                let thumbnail = self.makeThumbnail(from: processedData)
                let finalSize = processedData.count
                self.updateCarouselItem(captureID) {
                    $0.finalSize = finalSize
                    $0.thumbnail = thumbnail
                }
                PhotoSaver.saveLivePhoto(imageData: processedData, movieURL: movieURL) { [weak self] result in
                    self?.cleanupTempFile(at: movieURL)
                    self?.completeCapture(captureID: captureID, result: result)
                }
            } catch {
                self.cleanupTempFile(at: movieURL)
                self.completeCapture(captureID: captureID, result: .failure(error))
            }
        }
    }

    private func completeCapture(captureID: Int64, result: Result<Void, Error>) {
        guard let context = activeCaptures.removeValue(forKey: captureID) else { return }
        switch result {
        case .success:
            // Use processingStartTime (stamped when image data arrives) so the
            // reported duration reflects only the processing+saving work for this
            // individual photo, not burst queue wait time from earlier photos.
            let ref = context.processingStartTime > 0 ? context.processingStartTime : context.startTime
            let elapsed = CFAbsoluteTimeGetCurrent() - ref
            lastPostLatencyMs = Int(elapsed * 1000)
            bumpDone()
            updateCarouselItem(captureID) { $0.status = .ready }
            scheduleCarouselEviction(captureID)
            context.completion(.success(elapsed))
        case .failure(let error):
            updateCarouselItem(captureID) { $0.status = .failed }
            scheduleCarouselEviction(captureID)
            context.completion(.failure(error))
        }
        endBackgroundTaskIfDone()
    }

    private func cleanupTempFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Focus & Exposure

    /// Minimum exposure change (in EV stops) required to show the auto-exposure indicator.
    /// 1.0 EV = one full stop (exposure doubles or halves). Micro-corrections stay silent.
    private static let autoExposureEVThreshold: Double = 1.0

    /// Computes the current exposure value (EV) from the device's ISO and exposure duration.
    /// EV increases with brighter exposure; each stop is a factor of 2.
    private func currentEV(from device: AVCaptureDevice) -> Double {
        let iso = Double(device.iso)
        let duration = device.exposureDuration.seconds
        guard iso > 0, duration > 0 else { return 0 }
        return log2(iso / 100.0) + log2(1.0 / duration)
    }

    /// Observes `isAdjustingExposure` on `device`. Records EV when adjustment starts,
    /// then compares with EV when it ends. Only fires `onAutoExposureAdjust` when the
    /// change exceeds the threshold — suppressing constant micro-corrections.
    private func attachExposureObserver(to device: AVCaptureDevice) {
        exposureObservation?.invalidate()
        var preAdjustmentEV: Double?

        exposureObservation = device.observe(\.isAdjustingExposure, options: .new) { [weak self, weak device] _, change in
            guard let self = self, let device = device,
                  !self.isTapAdjusting else { return }

            if change.newValue == true {
                // Adjustment starting — snapshot the current EV
                preAdjustmentEV = self.currentEV(from: device)
            } else if change.newValue == false, let startEV = preAdjustmentEV {
                // Adjustment done — compare with new settled EV
                let endEV = self.currentEV(from: device)
                preAdjustmentEV = nil
                guard abs(endEV - startEV) >= Self.autoExposureEVThreshold else { return }
                DispatchQueue.main.async {
                    self.onAutoExposureAdjust?()
                }
            }
        }
    }

    /// Locks focus and exposure to the tapped point, then returns to continuous tracking.
    /// `tapPoint` is in the coordinate space of the preview view; `viewSize` is its bounds size.
    func setFocusAndExposure(at tapPoint: CGPoint, in viewSize: CGSize) {
        guard let device = currentInput?.device else { return }

        // Convert portrait view coordinates → normalized camera device coordinates.
        // The sensor is natively landscape-right; our preview is rotated 90° to portrait.
        //   cameraX = tapY / viewHeight   (portrait top  → sensor left)
        //   cameraY = 1 − tapX / viewWidth (portrait left → sensor bottom)
        let cameraPoint = CGPoint(
            x: tapPoint.y / viewSize.height,
            y: 1.0 - tapPoint.x / viewSize.width
        )

        isTapAdjusting = true

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported,
               device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = cameraPoint
                device.focusMode = .autoFocus
            }

            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = cameraPoint
                device.exposureMode = .autoExpose
            }

            device.unlockForConfiguration()
        } catch {
            isTapAdjusting = false
            return
        }

        // Once the one-shot focus/expose finishes, switch back to continuous
        // tracking so the camera keeps following the scene naturally.
        focusObservation?.invalidate()
        focusObservation = device.observe(\.isAdjustingFocus, options: .new) { [weak self, weak device] _, change in
            guard let device = device,
                  change.newValue == false else { return }

            self?.focusObservation?.invalidate()
            self?.focusObservation = nil
            self?.isTapAdjusting = false

            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
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

    /// Increments the dropped-frame counter when the app can't keep up with
    /// the camera's output rate. `alwaysDiscardsLateVideoFrames = true` means
    /// this fires whenever the render pipeline is the bottleneck.
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrames += 1
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case noRAWFormat
    case noImageData
    case livePhotoVideoProcessingFailed

    var errorDescription: String? {
        switch self {
        case .noRAWFormat: return "No RAW format available."
        case .noImageData: return "Failed to get image data."
        case .livePhotoVideoProcessingFailed: return "Failed to process Live Photo video."
        }
    }
}
