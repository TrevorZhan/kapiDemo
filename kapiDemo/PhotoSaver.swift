//
//  PhotoSaver.swift
//  kapiDemo
//

import Photos
import UIKit

enum PhotoSaver {

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

    private static func withAuthorization(_ block: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            block(status == .authorized || status == .limited)
        }
    }
}

enum SaveError: LocalizedError {
    case notAuthorized
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Photo library access not authorized."
        case .saveFailed: return "Failed to save image to photo library."
        }
    }
}
