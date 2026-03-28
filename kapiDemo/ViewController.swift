//
//  ViewController.swift
//  kapiDemo
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    private let cameraManager = CameraManager()
    private let statusLabel = UILabel()
    private let captureButton = UIButton(type: .system)
    private let previewContainer = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewContainer.bounds
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Preview container — sits above the capture button
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = .black
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        view.addSubview(previewContainer)

        // Status label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        statusLabel.text = "Initializing..."
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        view.addSubview(statusLabel)

        // Capture button — white circle with black stroke
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 35
        captureButton.layer.borderWidth = 3
        captureButton.layer.borderColor = UIColor.black.cgColor
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            // Status label: top of safe area
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),

            // Preview container: between label and button, 4:3 aspect ratio
            previewContainer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            previewContainer.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -16),
            previewContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewContainer.widthAnchor.constraint(equalTo: previewContainer.heightAnchor, multiplier: 3.0 / 4.0),

            // Capture button: bottom center
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 70),
            captureButton.heightAnchor.constraint(equalToConstant: 70),
        ])
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        cameraManager.configure { [weak self] success in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if success {
                    self.attachPreview()
                    self.updateLabel()
                } else {
                    self.statusLabel.text = "Camera unavailable"
                }
            }
        }
    }

    private func attachPreview() {
        let layer = cameraManager.makePreviewLayer()
        layer.frame = previewContainer.bounds
        layer.videoGravity = .resizeAspectFill
        previewContainer.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func updateLabel() {
        if cameraManager.isProRAWSupported {
            statusLabel.text = " ProRAW mode "
        } else {
            statusLabel.text = " Fallback: JPEG/HEIC "
        }
    }

    // MARK: - Capture

    @objc private func captureButtonTapped() {
        captureButton.isEnabled = false
        cameraManager.capturePhoto { [weak self] result in
            DispatchQueue.main.async {
                self?.captureButton.isEnabled = true
                switch result {
                case .success:
                    self?.showAlert(title: "Saved", message: "Photo saved to library.")
                case .failure(let error):
                    self?.showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
