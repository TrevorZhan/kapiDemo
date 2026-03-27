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
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - UI Setup

    private func setupUI() {
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

        // Capture button
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setTitle("Capture", for: .normal)
        captureButton.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.backgroundColor = UIColor.systemRed
        captureButton.layer.cornerRadius = 35
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),

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
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
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
