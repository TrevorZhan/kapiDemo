//
//  ViewController.swift
//  kapiDemo
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    private let cameraManager = CameraManager()
    private let statusLabel = UILabel()
    private let captureButton = UIButton(type: .custom)
    private let previewContainer = UIView()
    private let filteredPreview = FilteredPreviewView(frame: .zero, device: nil)
    private let toastLabel = UILabel()
    private let lensStack = UIStackView()
    private var lensButtons: [Lens: UIButton] = [:]
    private let resolutionButton = UIButton(type: .custom)
    private let filterToggleButton = UIButton(type: .custom)
    private let livePhotoButton = UIButton(type: .custom)
    private let flashOverlay = UIView()
    private let focusIndicator = UIView()
    private let autoExposureIndicator = UIView()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()
    private let focusFeedback = UIImpactFeedbackGenerator(style: .light)
    private var toastHideWorkItem: DispatchWorkItem?
    private var focusHideWorkItem: DispatchWorkItem?
    private var autoExposureHideWorkItem: DispatchWorkItem?

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

    // MARK: - Pill Button Helper

    /// Creates a UIButton.Configuration styled as a rounded pill with the given parameters.
    private static func pillConfig(
        title: String,
        foreground: UIColor,
        background: UIColor
    ) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = foreground
        config.baseBackgroundColor = background
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        return config
    }

    private static let activeBackground = UIColor.yellow.withAlphaComponent(0.9)
    private static let inactiveBackground = UIColor.black.withAlphaComponent(0.5)
    private static let activeForeground = UIColor.black
    private static let inactiveForeground = UIColor.white

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

        // Status label — tappable on Pro devices to switch pipeline
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        statusLabel.text = "Initializing..."
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pipelineToggleTapped)))
        view.addSubview(statusLabel)

        // Capture button — white circle with black stroke
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 35
        captureButton.layer.borderWidth = 3
        captureButton.layer.borderColor = UIColor.black.cgColor
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        captureButton.addTarget(self, action: #selector(captureButtonTouchDown), for: .touchDown)
        captureButton.addTarget(self, action: #selector(captureButtonTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(captureButton)

        // White flash overlay on the preview
        flashOverlay.translatesAutoresizingMaskIntoConstraints = false
        flashOverlay.backgroundColor = .white
        flashOverlay.alpha = 0
        flashOverlay.isUserInteractionEnabled = false
        previewContainer.addSubview(flashOverlay)

        // Focus indicator — yellow square border, positioned at tap point
        focusIndicator.frame = CGRect(x: 0, y: 0, width: 75, height: 75)
        focusIndicator.backgroundColor = .clear
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.borderWidth = 1.5
        focusIndicator.alpha = 0
        focusIndicator.isUserInteractionEnabled = false
        previewContainer.addSubview(focusIndicator)

        // Auto-exposure indicator — slightly larger box, centered, fades in when camera
        // autonomously adjusts exposure (e.g. walking from bright outdoors to indoors).
        autoExposureIndicator.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        autoExposureIndicator.backgroundColor = .clear
        autoExposureIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        autoExposureIndicator.layer.borderWidth = 1.5
        autoExposureIndicator.alpha = 0
        autoExposureIndicator.isUserInteractionEnabled = false
        previewContainer.addSubview(autoExposureIndicator)

        // Tap gesture on the preview to focus/expose
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(previewTapped(_:)))
        previewContainer.addGestureRecognizer(tapGesture)

        // Lens selector stack — populated after camera configure
        lensStack.translatesAutoresizingMaskIntoConstraints = false
        lensStack.axis = .horizontal
        lensStack.alignment = .center
        lensStack.distribution = .equalSpacing
        lensStack.spacing = 12
        view.addSubview(lensStack)

        // Filter toggle (Preview on/off)
        filterToggleButton.translatesAutoresizingMaskIntoConstraints = false
        filterToggleButton.configuration = Self.pillConfig(
            title: "Preview",
            foreground: Self.activeForeground,
            background: Self.activeBackground
        )
        filterToggleButton.addTarget(self, action: #selector(filterToggleTapped), for: .touchUpInside)
        view.addSubview(filterToggleButton)

        // Live Photo toggle
        livePhotoButton.translatesAutoresizingMaskIntoConstraints = false
        livePhotoButton.configuration = Self.pillConfig(
            title: "Live",
            foreground: Self.inactiveForeground,
            background: Self.inactiveBackground
        )
        livePhotoButton.addTarget(self, action: #selector(livePhotoToggleTapped), for: .touchUpInside)
        livePhotoButton.isHidden = true
        view.addSubview(livePhotoButton)

        // Resolution toggle (12MP / 48MP)
        resolutionButton.translatesAutoresizingMaskIntoConstraints = false
        resolutionButton.configuration = Self.pillConfig(
            title: "12MP",
            foreground: Self.inactiveForeground,
            background: Self.inactiveBackground
        )
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

            // Flash overlay fills the preview
            flashOverlay.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            flashOverlay.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            flashOverlay.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            flashOverlay.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            // Capture button: bottom center
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 70),
            captureButton.heightAnchor.constraint(equalToConstant: 70),

            // Lens selector: between preview and capture button
            lensStack.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -16),
            lensStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lensStack.heightAnchor.constraint(equalToConstant: 40),

            // Filter toggle: left side, same row as status label
            filterToggleButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            filterToggleButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            filterToggleButton.heightAnchor.constraint(equalToConstant: 36),

            // Live Photo toggle: right side, same row as status label
            livePhotoButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            livePhotoButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            livePhotoButton.heightAnchor.constraint(equalToConstant: 36),

            // Resolution toggle: top-right of the preview
            resolutionButton.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            resolutionButton.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            resolutionButton.heightAnchor.constraint(equalToConstant: 36),

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
        cameraManager.onAutoExposureAdjust = { [weak self] in
            self?.showAutoExposureIndicator()
        }
        cameraManager.configure { [weak self] success in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if success {
                    self.updateLabel()
                    self.buildLensButtons()
                    self.updateResolutionButton()
                    self.updateLivePhotoButton()
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
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.configuration = Self.pillConfig(
                title: lens.label,
                foreground: Self.inactiveForeground,
                background: Self.inactiveBackground
            )
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
            button.configuration?.baseForegroundColor = isActive ? Self.activeForeground : Self.inactiveForeground
            button.configuration?.baseBackgroundColor = isActive ? Self.activeBackground : Self.inactiveBackground
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
        let active = cameraManager.is48MPEnabled
        resolutionButton.configuration?.title = active ? "48MP" : "12MP"
        resolutionButton.configuration?.baseForegroundColor = active ? Self.activeForeground : Self.inactiveForeground
        resolutionButton.configuration?.baseBackgroundColor = active ? Self.activeBackground : Self.inactiveBackground
    }

    @objc private func resolutionButtonTapped() {
        cameraManager.is48MPEnabled.toggle()
        updateResolutionButton()
    }

    // MARK: - Live Photo Toggle

    private func updateLivePhotoButton() {
        livePhotoButton.isHidden = !cameraManager.isLivePhotoCaptureSupported
        let active = cameraManager.isLivePhotoMode
        livePhotoButton.configuration?.baseForegroundColor = active ? Self.activeForeground : Self.inactiveForeground
        livePhotoButton.configuration?.baseBackgroundColor = active ? Self.activeBackground : Self.inactiveBackground
    }

    @objc private func livePhotoToggleTapped() {
        cameraManager.isLivePhotoMode.toggle()
        // Live Photo and ProRAW are mutually exclusive
        if cameraManager.isLivePhotoMode {
            cameraManager.useProRAW = false
            updateLabel()
        }
        updateLivePhotoButton()
    }

    // MARK: - Filter Toggle

    @objc private func filterToggleTapped() {
        filteredPreview.isFilterEnabled.toggle()
        let enabled = filteredPreview.isFilterEnabled
        filterToggleButton.configuration?.baseForegroundColor = enabled ? Self.activeForeground : Self.inactiveForeground
        filterToggleButton.configuration?.baseBackgroundColor = enabled ? Self.activeBackground : Self.inactiveBackground
    }

    private func updateLabel() {
        if cameraManager.isProRAWSupported {
            if cameraManager.useProRAW {
                statusLabel.text = " ProRAW "
                statusLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8)
            } else {
                statusLabel.text = " JPEG/HEIC "
                statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            }
        } else {
            statusLabel.text = " JPEG/HEIC "
            statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        }
    }

    @objc private func pipelineToggleTapped() {
        guard cameraManager.isProRAWSupported else { return }
        cameraManager.useProRAW.toggle()
        // ProRAW and Live Photo are mutually exclusive
        if cameraManager.useProRAW {
            cameraManager.isLivePhotoMode = false
            updateLivePhotoButton()
        }
        updateLabel()
    }

    // MARK: - Tap to Focus / Expose

    /// Shows a slightly larger centered box when the camera auto-adjusts exposure
    /// without user interaction (e.g. moving between lighting environments).
    private func showAutoExposureIndicator() {
        // Don't interrupt an in-progress auto-exposure animation
        guard autoExposureIndicator.alpha < 0.1 else { return }

        autoExposureIndicator.center = CGPoint(
            x: previewContainer.bounds.midX,
            y: previewContainer.bounds.midY
        )
        autoExposureHideWorkItem?.cancel()

        UIView.animate(withDuration: 0.2) {
            self.autoExposureIndicator.alpha = 1
        }

        let hideWork = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.autoExposureIndicator.alpha = 0 }
        }
        autoExposureHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: hideWork)
    }

    @objc private func previewTapped(_ gesture: UITapGestureRecognizer) {
        let tapPoint = gesture.location(in: previewContainer)

        // Animate the focus indicator to the tap point
        focusHideWorkItem?.cancel()
        focusIndicator.layer.removeAllAnimations()
        focusIndicator.center = tapPoint
        focusIndicator.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        focusIndicator.alpha = 1

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0,
            options: [],
            animations: { self.focusIndicator.transform = .identity }
        )

        let hideWork = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.focusIndicator.alpha = 0 }
        }
        focusHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWork)

        // Light haptic and adjust focus/exposure
        focusFeedback.impactOccurred()
        cameraManager.setFocusAndExposure(at: tapPoint, in: previewContainer.bounds.size)
    }

    // MARK: - Capture

    @objc private func captureButtonTouchDown() {
        impactFeedback.prepare()
        impactFeedback.impactOccurred()
        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            usingSpringWithDamping: 0.5,
            initialSpringVelocity: 0.5,
            options: [.allowUserInteraction],
            animations: { [weak self] in
                self?.captureButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            }
        )
    }

    @objc private func captureButtonTouchUp() {
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.5,
            options: [.allowUserInteraction],
            animations: { [weak self] in
                self?.captureButton.transform = .identity
            }
        )
    }

    @objc private func captureButtonTapped() {
        flashPreview()
        notificationFeedback.prepare()
        cameraManager.capturePhoto { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // If the app was backgrounded while this capture was processing,
                // skip all UI feedback — the photo is either in the album or not,
                // and a stale alert on return is more disruptive than informative.
                guard UIApplication.shared.applicationState == .active else { return }

                switch result {
                case .success(let elapsed):
                    self.notificationFeedback.notificationOccurred(.success)
                    let ms = Int((elapsed * 1000).rounded())
                    self.showToast("Saved in \(ms) ms")
                case .failure(let error):
                    self.notificationFeedback.notificationOccurred(.error)
                    self.showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    private func flashPreview() {
        // Cancel any in-flight animation and snap to visible immediately
        flashOverlay.layer.removeAllAnimations()
        flashOverlay.alpha = 1

        // Schedule the fade-out on a fixed delay so first-capture jank
        // doesn't stretch the animation duration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            UIView.animate(withDuration: 0.1) {
                self?.flashOverlay.alpha = 0
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
