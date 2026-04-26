//
//  CaptureItemCell.swift
//  kapiDemo
//
//  Cell for the bottom debug carousel showing per-capture status, file sizes,
//  and a thumbnail of each in-flight or recently completed photo.
//

import UIKit

final class CaptureItemCell: UICollectionViewCell {

    static let reuseID = "CaptureItemCell"

    private let imageView = UIImageView()
    private let placeholderView = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let bottomScrim = UIView()
    private let statusLabel = UILabel()
    private let sizeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true
        contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)

        // Thumbnail (or placeholder fill) — always full-bleed
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        // Solid grey placeholder shown while waiting for the thumbnail
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.backgroundColor = UIColor(white: 0.25, alpha: 1)
        contentView.addSubview(placeholderView)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        contentView.addSubview(activityIndicator)

        // Dim scrim across the bottom for legible text over the thumbnail
        bottomScrim.translatesAutoresizingMaskIntoConstraints = false
        bottomScrim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        contentView.addSubview(bottomScrim)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .white
        contentView.addSubview(statusLabel)

        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = .white
        sizeLabel.adjustsFontSizeToFitWidth = true
        sizeLabel.minimumScaleFactor = 0.7
        contentView.addSubview(sizeLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            placeholderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -8),

            bottomScrim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomScrim.heightAnchor.constraint(equalToConstant: 32),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            statusLabel.bottomAnchor.constraint(equalTo: sizeLabel.topAnchor, constant: -1),

            sizeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            sizeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            sizeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        placeholderView.isHidden = false
        activityIndicator.stopAnimating()
        statusLabel.text = nil
        sizeLabel.text = nil
    }

    func configure(with item: CaptureItem) {
        if let thumb = item.thumbnail {
            imageView.image = thumb
            placeholderView.isHidden = true
            activityIndicator.stopAnimating()
        } else {
            imageView.image = nil
            placeholderView.isHidden = false
            activityIndicator.startAnimating()
        }

        switch item.status {
        case .capturing:  statusLabel.text = "Capturing"
        case .finalizing: statusLabel.text = "Finalizing"
        case .ready:      statusLabel.text = "Final Ready"
        case .failed:     statusLabel.text = "Failed"
        }

        sizeLabel.text = formattedSize(for: item)

        // Slight tint on failed cells so they're easy to spot
        if case .failed = item.status {
            contentView.layer.borderColor = UIColor.systemRed.cgColor
            contentView.layer.borderWidth = 1.5
        } else {
            contentView.layer.borderWidth = 0
        }
    }

    /// "21.6MB → 47.3MB" once the final size is known, "21.6MB → ..." while
    /// processing, "..." when neither is available yet.
    private func formattedSize(for item: CaptureItem) -> String {
        let placeholder = item.placeholderSize > 0 ? mb(item.placeholderSize) : nil
        let final = item.finalSize.map(mb)
        switch (placeholder, final) {
        case let (.some(p), .some(f)): return "\(p) → \(f)"
        case let (.some(p), .none):    return "\(p) → ..."
        case (.none, _):               return "..."
        }
    }

    private func mb(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_000_000)
    }
}
