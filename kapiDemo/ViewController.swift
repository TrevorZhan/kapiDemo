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
    private let filteredPreview = FilteredPreviewView(frame: .zero, device: nil)
    private let toastLabel = UILabel()
    private let lensStack = UIStackView()
    private var lensButtons: [Lens: UIButton] = [:]
    private let resolutionButton = UIButton(type: .system)
    private let filterToggleButton = UIButton(type: .system)
    private var toastHideWorkItem: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        filteredPreview.frame = previewContainer.bounds
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Preview container — sits above the capture button
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = .black
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        view.addSubview(previewContainer)

        // Filtered live preview fills the container
        filteredPreview.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(filteredPreview)

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

        // Lens selector stack — populated after camera configure
        lensStack.translatesAutoresizingMaskIntoConstraints = false
        lensStack.axis = .horizontal
        lensStack.alignment = .center
        lensStack.distribution = .equalSpacing
        lensStack.spacing = 12
        view.addSubview(lensStack)

        // Filter toggle (LUT on/off)
        filterToggleButton.translatesAutoresizingMaskIntoConstraints = false
        filterToggleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        filterToggleButton.setTitle("LUT ON", for: .normal)
        filterToggleButton.setTitleColor(.black, for: .normal)
        filterToggleButton.backgroundColor = UIColor.yellow.withAlphaComponent(0.9)
        filterToggleButton.layer.cornerRadius = 18
        filterToggleButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        filterToggleButton.addTarget(self, action: #selector(filterToggleTapped), for: .touchUpInside)
        view.addSubview(filterToggleButton)

        // Resolution toggle (12MP / 48MP)
        resolutionButton.translatesAutoresizingMaskIntoConstraints = false
        resolutionButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        resolutionButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        resolutionButton.setTitleColor(.white, for: .normal)
        resolutionButton.layer.cornerRadius = 18
        resolutionButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        resolutionButton.addTarget(self, action: #selector(resolutionButtonTapped), for: .touchUpInside)
        resolutionButton.isHidden = true
        view.addSubview(resolutionButton)

        // Toast label — floating overlay for capture timing
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.textColor = .white
        toastLabel.textAlignment = .center
        toastLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toastLabel.layer.cornerRadius = 10
        toastLabel.clipsToBounds = true
        toastLabel.alpha = 0
        view.addSubview(toastLabel)

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

            // Filtered preview fills its container
            filteredPreview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            filteredPreview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            filteredPreview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            filteredPreview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            // Capture button: bottom center
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 70),
            captureButton.heightAnchor.constraint(equalToConstant: 70),

            // Lens selector: between preview and capture button
            lensStack.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -16),
            lensStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lensStack.heightAnchor.constraint(equalToConstant: 40),

            // Resolution toggle: top-right of the preview
            resolutionButton.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            resolutionButton.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            resolutionButton.heightAnchor.constraint(equalToConstant: 36),

            // Filter toggle: top-left of the preview
            filterToggleButton.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            filterToggleButton.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            filterToggleButton.heightAnchor.constraint(equalToConstant: 36),

            // Toast: floats above the lens selector
            toastLabel.bottomAnchor.constraint(equalTo: lensStack.topAnchor, constant: -12),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.heightAnchor.constraint(equalToConstant: 36),
            toastLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        cameraManager.filteredPreview = filteredPreview
        cameraManager.configure { [weak self] success in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if success {
                    self.updateLabel()
                    self.buildLensButtons()
                    self.updateResolutionButton()
                } else {
                    self.statusLabel.text = "Camera unavailable"
                }
            }
        }
    }

    // MARK: - Lens Buttons

    private func buildLensButtons() {
        lensStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lensButtons.removeAll()

        for lens in cameraManager.availableLenses {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(lens.label, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            button.layer.cornerRadius = 18
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            button.addTarget(self, action: #selector(lensButtonTapped(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            lensStack.addArrangedSubview(button)
            lensButtons[lens] = button
        }

        updateLensButtonStates()
    }

    private func updateLensButtonStates() {
        for (lens, button) in lensButtons {
            let isActive = lens == cameraManager.currentLens
            button.backgroundColor = isActive
                ? UIColor.yellow.withAlphaComponent(0.9)
                : UIColor.black.withAlphaComponent(0.5)
            button.setTitleColor(isActive ? .black : .white, for: .normal)
        }
    }

    @objc private func lensButtonTapped(_ sender: UIButton) {
        guard let lens = lensButtons.first(where: { $0.value === sender })?.key else { return }
        lensButtons.values.forEach { $0.isEnabled = false }
        cameraManager.switchLens(to: lens) { [weak self] success in
            guard let self = self else { return }
            self.lensButtons.values.forEach { $0.isEnabled = true }
            if success {
                self.updateLensButtonStates()
                self.updateResolutionButton()
            } else {
                self.showToast("Lens switch failed")
            }
        }
    }

    // MARK: - Resolution Toggle

    private func updateResolutionButton() {
        resolutionButton.isHidden = !cameraManager.is48MPSupported
        let title = cameraManager.is48MPEnabled ? "48MP" : "12MP"
        resolutionButton.setTitle(title, for: .normal)
        resolutionButton.backgroundColor = cameraManager.is48MPEnabled
            ? UIColor.yellow.withAlphaComponent(0.9)
            : UIColor.black.withAlphaComponent(0.5)
        resolutionButton.setTitleColor(cameraManager.is48MPEnabled ? .black : .white, for: .normal)
    }

    @objc private func resolutionButtonTapped() {
        cameraManager.is48MPEnabled.toggle()
        updateResolutionButton()
    }

    // MARK: - Filter Toggle

    @objc private func filterToggleTapped() {
        filteredPreview.isFilterEnabled.toggle()
        let enabled = filteredPreview.isFilterEnabled
        filterToggleButton.setTitle(enabled ? "LUT ON" : "LUT OFF", for: .normal)
        filterToggleButton.backgroundColor = enabled
            ? UIColor.yellow.withAlphaComponent(0.9)
            : UIColor.black.withAlphaComponent(0.5)
        filterToggleButton.setTitleColor(enabled ? .black : .white, for: .normal)
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
                case .success(let elapsed):
                    let ms = Int((elapsed * 1000).rounded())
                    self?.showToast("Saved in \(ms) ms")
                case .failure(let error):
                    self?.showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    private func showToast(_ text: String) {
        toastHideWorkItem?.cancel()
        toastLabel.text = "  \(text)  "
        UIView.animate(withDuration: 0.2) {
            self.toastLabel.alpha = 1
        }
        let workItem = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) {
                self?.toastLabel.alpha = 0
            }
        }
        toastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
