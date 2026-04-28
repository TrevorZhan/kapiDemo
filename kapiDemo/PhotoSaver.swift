//
//  PhotoSaver.swift
//  kapiDemo
//

import CoreImage
import Photos
import UIKit

enum PhotoSaver {

    // MARK: - Single-shot save

    static func save(imageData: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        withAuthorization { authorized in
            guard authorized else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: nil)
            }) { success, error in
                if let error = error {
                    completion(.failure(error))
                } else if success {
                    completion(.success(()))
                } else {
                    completion(.failure(SaveError.saveFailed))
                }
            }
        }
    }

    static func saveLivePhoto(imageData: Data, movieURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        withAuthorization { authorized in
            guard authorized else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: nil)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true // move instead of copy — avoids temp file duplication
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)
            }) { success, error in
                if let error = error {
                    completion(.failure(error))
                } else if success {
                    completion(.success(()))
                } else {
                    completion(.failure(SaveError.saveFailed))
                }
            }
        }
    }

    // MARK: - Deferred-delivery pipeline (Live Photos)

    /// Live Photo placeholder: pairs a small LUT-applied still (full display
    /// dims, upscaled, `.up` orientation) with the un-LUT'd source movie. The
    /// movie is moved into Photos' storage. Returns the asset's
    /// `localIdentifier` so the upgrade can edit it in place.
    ///
    /// The still must already have the matching content identifier embedded
    /// in its MakerApple dictionary, otherwise Photos won't recognize the
    /// pair as a Live Photo.
    static func saveLivePhotoPlaceholder(
        imageData: Data,
        movieURL: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        withAuthorization { authorized in
            guard authorized else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            var assetID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.uniformTypeIdentifier = "public.jpeg"
                request.addResource(with: .photo, data: imageData, options: photoOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)

                assetID = request.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if let error = error {
                    completion(.failure(error))
                } else if success, let assetID = assetID {
                    completion(.success(assetID))
                } else {
                    completion(.failure(SaveError.saveFailed))
                }
            }
        }
    }

    /// Upgrades a Live Photo placeholder. Both resources are replaced via
    /// `PHLivePhotoEditingContext`:
    ///   - the `.photo` frame is swapped for the pre-rendered full-res LUT'd
    ///     still (`finalImageData`), so we don't recompute the still LUT
    ///     against the upscaled placeholder pixels
    ///   - each `.video` frame gets the LUT applied here — this is when the
    ///     deferred video processing actually happens
    ///
    /// The video LUT uses a dedicated filter instance — the shared cached
    /// filter is not thread-safe and may be in use by other concurrent
    /// captures.
    static func upgradeLivePhoto(
        localIdentifier: String,
        finalImageData: Data,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        withAuthorization { authorized in
            guard authorized else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetched.firstObject else {
                completion(.failure(SaveError.assetNotFound))
                return
            }

            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false

            asset.requestContentEditingInput(with: options) { input, _ in
                guard let input = input else {
                    completion(.failure(SaveError.editingInputUnavailable))
                    return
                }
                guard let editingContext = PHLivePhotoEditingContext(livePhotoEditingInput: input) else {
                    completion(.failure(SaveError.livePhotoEditingContextUnavailable))
                    return
                }

                // Pre-rendered full-res LUT'd still — handed back unchanged for
                // the photo frame. Pixel dims match the placeholder still
                // (both produced at full display dims with `.up` orientation).
                let finalStill = CIImage(data: finalImageData)

                // Dedicated LUT filter for video frames so we don't race the
                // shared cached filter against concurrent captures.
                let videoLUT = ImageProcessor.createLUTFilter()

                editingContext.frameProcessor = { frame, _ in
                    switch frame.type {
                    case .photo:
                        return finalStill ?? frame.image
                    case .video:
                        guard let videoLUT = videoLUT else { return frame.image }
                        videoLUT.setValue(frame.image, forKey: kCIInputImageKey)
                        return videoLUT.outputImage ?? frame.image
                    @unknown default:
                        return frame.image
                    }
                }

                let output = PHContentEditingOutput(contentEditingInput: input)
                let payload = "kapi-deferred-live-upgrade-v1".data(using: .utf8) ?? Data()
                output.adjustmentData = PHAdjustmentData(
                    formatIdentifier: "com.kapi.lut.live",
                    formatVersion: "1.0",
                    data: payload
                )

                editingContext.saveLivePhoto(to: output, options: nil) { success, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    guard success else {
                        completion(.failure(SaveError.saveFailed))
                        return
                    }

                    // The editing context re-encoded our CIImage into a JPEG at
                    // its own (lower) default quality. Stomp it with the
                    // pre-encoded `finalImageData` (quality 1.0) so the rendered
                    // still matches what the stills-pipeline upgrade produces.
                    // The video file the editing context wrote is left intact.
                    do {
                        try finalImageData.write(to: output.renderedContentURL, options: .atomic)
                    } catch {
                        completion(.failure(error))
                        return
                    }

                    PHPhotoLibrary.shared().performChanges({
                        let request = PHAssetChangeRequest(for: asset)
                        request.contentEditingOutput = output
                    }) { commitSuccess, commitError in
                        if let commitError = commitError {
                            completion(.failure(commitError))
                        } else if commitSuccess {
                            completion(.success(()))
                        } else {
                            completion(.failure(SaveError.saveFailed))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Deferred-delivery pipeline

    /// Saves a low-resolution, LUT-applied JPEG as a new Photos asset and returns its
    /// `localIdentifier`. The asset becomes visible in the gallery immediately so the
    /// user has something to look at while we finish processing the full-res version
    /// in the background.
    static func savePlaceholder(imageData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        withAuthorization { authorized in
            guard authorized else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            var assetID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "public.jpeg"
                request.addResource(with: .photo, data: imageData, options: options)
                assetID = request.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if let error = error {
                    completion(.failure(error))
                } else if success, let assetID = assetID {
                    completion(.success(assetID))
                } else {
                    completion(.failure(SaveError.saveFailed))
                }
            }
        }
    }

    /// Replaces the image resource of an existing Photos asset (identified by
    /// `localIdentifier`) with `finalData`, preserving the asset's identity,
    /// creation date, and any pairings. Used by the deferred-delivery pipeline
    /// to swap the small placeholder for the full-res LUT-applied final.
    ///
    /// Uses `PHContentEditingOutput`, which means Photos will treat the asset as
    /// "Edited" and let the user revert. That's intentional and useful for
    /// debugging — it makes the placeholder→final transition observable.
    static func upgradePhoto(
        localIdentifier: String,
        finalData: Data,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        withAuthorization { authorized in
            guard authorized else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetched.firstObject else {
                completion(.failure(SaveError.assetNotFound))
                return
            }

            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false

            asset.requestContentEditingInput(with: options) { input, _ in
                guard let input = input else {
                    completion(.failure(SaveError.editingInputUnavailable))
                    return
                }

                let output = PHContentEditingOutput(contentEditingInput: input)

                // Adjustment data identifies the edit as ours so Photos shows
                // the standard "Edited" badge and lets the user revert.
                let payload = "kapi-deferred-upgrade-v1".data(using: .utf8) ?? Data()
                output.adjustmentData = PHAdjustmentData(
                    formatIdentifier: "com.kapi.lut",
                    formatVersion: "1.0",
                    data: payload
                )

                do {
                    try finalData.write(to: output.renderedContentURL, options: .atomic)
                } catch {
                    completion(.failure(error))
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetChangeRequest(for: asset)
                    request.contentEditingOutput = output
                }) { success, error in
                    if let error = error {
                        completion(.failure(error))
                    } else if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(SaveError.saveFailed))
                    }
                }
            }
        }
    }

    // MARK: - Authorization

    /// Requests `.readWrite` access — needed for content-editing the placeholder
    /// asset during the deferred-delivery upgrade. `.addOnly` would block the
    /// `PHAssetChangeRequest(for:)` step.
    private static func withAuthorization(_ block: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            block(status == .authorized || status == .limited)
        }
    }
}

enum SaveError: LocalizedError {
    case notAuthorized
    case saveFailed
    case assetNotFound
    case editingInputUnavailable
    case livePhotoEditingContextUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:                    return "Photo library access not authorized."
        case .saveFailed:                       return "Failed to save image to photo library."
        case .assetNotFound:                    return "Placeholder asset disappeared before upgrade."
        case .editingInputUnavailable:          return "Could not open placeholder asset for editing."
        case .livePhotoEditingContextUnavailable: return "Could not open Live Photo placeholder for editing."
        }
    }
}
