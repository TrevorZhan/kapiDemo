//
//  PhotoSaver.swift
//  kapiDemo
//

import Photos
import UIKit

enum PhotoSaver {

    static func save(image: UIImage, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(SaveError.notAuthorized))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
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
