//
//  VideoProcessor.swift
//  kapiDemo
//
//  Applies the cached LUT filter to a Live Photo video frame-by-frame,
//  preserving the content identifier and still-image-time metadata required
//  for Photos to recognize the result as a valid Live Photo pair.
//

import AVFoundation
import CoreImage

enum VideoProcessor {

    private static let ciContext = CIContext()

    /// Reads the video at `inputURL`, applies the LUT to each frame, preserves
    /// Live Photo metadata, and writes a new video to a temp URL.
    /// Calls `completion` with the processed file URL, or nil on failure.
    static func applyLUT(to inputURL: URL, completion: @escaping (URL?) -> Void) {
        Task {
            let result = await processVideo(at: inputURL)
            completion(result)
        }
    }

    /// Reads the content identifier from the source Live Photo movie's QuickTime metadata.
    static func readContentIdentifier(from url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if item.identifier == AVMetadataIdentifier.quickTimeMetadataContentIdentifier {
                    return try? await item.load(.stringValue)
                }
            }
        } catch {
            // ignore
        }
        return nil
    }

    private static func processVideo(at inputURL: URL) async -> URL? {
        let asset = AVURLAsset(url: inputURL)

        // Read the content identifier before processing
        let contentIdentifier = await readContentIdentifier(from: inputURL)

        // Load tracks asynchronously
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let metadataTrack = try? await asset.loadTracks(withMediaType: .metadata).first

        // Load video track properties
        guard let naturalSize = try? await videoTrack.load(.naturalSize),
              let preferredTransform = try? await videoTrack.load(.preferredTransform) else { return nil }

        // --- Reader ---
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        // Video track
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        // Audio track (optional)
        var audioOutput: AVAssetReaderTrackOutput?
        if let aTrack = audioTrack {
            let aOutput = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            aOutput.alwaysCopiesSampleData = false
            if reader.canAdd(aOutput) {
                reader.add(aOutput)
                audioOutput = aOutput
            }
        }

        // Timed metadata track (contains still-image-time marker)
        var metadataOutput: AVAssetReaderTrackOutput?
        if let mTrack = metadataTrack {
            let mOutput = AVAssetReaderTrackOutput(track: mTrack, outputSettings: nil)
            mOutput.alwaysCopiesSampleData = false
            if reader.canAdd(mOutput) {
                reader.add(mOutput)
                metadataOutput = mOutput
            }
        }

        // --- Writer ---
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }

        // Write the content identifier as file-level QuickTime metadata
        if let identifier = contentIdentifier {
            let idItem = AVMutableMetadataItem()
            idItem.identifier = AVMetadataIdentifier.quickTimeMetadataContentIdentifier
            idItem.dataType = kCMMetadataBaseDataType_UTF8 as String
            idItem.value = identifier as NSString
            writer.metadata = [idItem]
        }

        // Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: naturalSize.width,
            AVVideoHeightKey: naturalSize.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = preferredTransform
        videoInput.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(naturalSize.width),
            kCVPixelBufferHeightKey as String: Int(naturalSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttrs
        )
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        // Audio input (passthrough)
        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }

        // Timed metadata input — copies still-image-time + video-orientation markers.
        // Use the source track's format descriptions so all item types are declared.
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let mTrack = metadataTrack {
            let formatDescriptions = (try? await mTrack.load(.formatDescriptions)) ?? []
            if let firstDesc = formatDescriptions.first {
                let sourceFormatDesc = firstDesc as CMFormatDescription
                let mInput = AVAssetWriterInput(mediaType: .metadata,
                                                outputSettings: nil,
                                                sourceFormatHint: sourceFormatDesc)
                mInput.expectsMediaDataInRealTime = false
                if writer.canAdd(mInput) {
                    writer.add(mInput)
                    metadataInput = mInput
                    metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mInput)
                }
            }
        }

        // --- Process ---
        guard reader.startReading() else { return nil }
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()

        // Process video frames
        group.enter()
        let videoQueue = DispatchQueue(label: "video.processor.video", qos: .userInitiated)
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard reader.status == .reading,
                      let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continue
                }

                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let filtered = ImageProcessor.applyCachedLUT(to: ciImage) ?? ciImage

                guard let pool = adaptor.pixelBufferPool else { continue }
                var outputBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                guard let outBuf = outputBuffer else { continue }

                ciContext.render(filtered, to: outBuf)
                adaptor.append(outBuf, withPresentationTime: presentationTime)
            }
        }

        // Copy audio
        if let audioOutput = audioOutput, let audioInput = audioInput {
            group.enter()
            let audioQueue = DispatchQueue(label: "video.processor.audio", qos: .userInitiated)
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(sampleBuffer)
                }
            }
        }

        // Copy timed metadata (still-image-time)
        if let metadataOutput = metadataOutput, let metadataInput = metadataInput,
           let metadataAdaptor = metadataAdaptor {
            group.enter()
            let metadataQueue = DispatchQueue(label: "video.processor.metadata", qos: .userInitiated)
            metadataInput.requestMediaDataWhenReady(on: metadataQueue) {
                while metadataInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sampleBuffer = metadataOutput.copyNextSampleBuffer() else {
                        metadataInput.markAsFinished()
                        group.leave()
                        return
                    }

                    // Re-create the timed metadata group from the sample buffer
                    guard let groupRef = AVTimedMetadataGroup(sampleBuffer: sampleBuffer) else {
                        continue
                    }
                    metadataAdaptor.append(groupRef)
                }
            }
        }

        // Wait for all tracks to finish on a background thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                continuation.resume()
            }
        }

        // Finalize
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else { return nil }
        return outputURL
    }
}
