// WebtoonCells.swift - The cells of the webtoon strip.

import SwiftUI
import UIKit

/// One page. Owns its own load, so a slow page never blocks its neighbours, and
/// gives its bitmap back when it is reused.
final class WebtoonPageCell: UICollectionViewCell {
    static let reuseID = "page"

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failure = UIStackView()
    private let failureLabel = UILabel()
    private var task: Task<Void, Never>?
    private var retry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        contentView.addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        failureLabel.font = .preferredFont(forTextStyle: .footnote)
        failureLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        var config = UIButton.Configuration.bordered()
        config.title = "Retry"
        config.baseForegroundColor = .white
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.retry?() }, for: .touchUpInside)
        failure.axis = .vertical
        failure.spacing = 14
        failure.alignment = .center
        failure.addArrangedSubview(failureLabel)
        failure.addArrangedSubview(button)
        failure.isHidden = true
        failure.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(failure)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failure.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failure.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let image = imageView.image, image.size.width > 0 {
            // Anchor to the top of the cell: webtoon strips connect vertically,
            // so an image must not center vertically when its slot resizes.
            let targetHeight = contentView.bounds.width * (image.size.height / image.size.width)
            imageView.frame = CGRect(
                x: 0,
                y: 0,
                width: contentView.bounds.width,
                height: max(contentView.bounds.height, targetHeight)
            )
        } else {
            imageView.frame = contentView.bounds
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        imageView.image = nil
        imageView.frame = contentView.bounds
        failure.isHidden = true
        spinner.stopAnimating()
    }

    @MainActor
    func show(page: SourcePage, sourceKey: String, loader: PageLoader, targetWidth: CGFloat, scale: CGFloat) {
        task?.cancel()
        failure.isHidden = true
        retry = { [weak self] in
            self?.show(page: page, sourceKey: sourceKey, loader: loader, targetWidth: targetWidth, scale: scale)
        }

        if let cached = PageImageCache.shared.object(forKey: page.url as NSString) {
            imageView.image = cached
            setNeedsLayout()
            spinner.stopAnimating()
            return
        }
        imageView.image = nil
        setNeedsLayout()
        spinner.startAnimating()

        task = Task { @MainActor [weak self] in
            do {
                let data = try await loader.image(for: page, sourceKey: sourceKey)
                guard !Task.isCancelled else { return }
                // The slot learns its real height before the decode finishes.
                PageImageCache.noteRatio(from: data, forKey: page.url)
                let decoded = await PageDecode.decode(data, targetWidth: targetWidth, screenScale: scale)
                guard !Task.isCancelled else { return }
                guard let decoded else {
                    throw HTTPError.transport("Page \(page.index + 1) is not a valid image")
                }
                PageImageCache.store(decoded, forKey: page.url)
                self?.imageView.image = decoded
                self?.setNeedsLayout()
                self?.spinner.stopAnimating()
            } catch {
                guard !Task.isCancelled else { return }
                self?.failureLabel.text = "Page \(page.index + 1) could not be loaded"
                self?.failure.isHidden = false
                self?.spinner.stopAnimating()
            }
        }
    }
}

/// The divider between two stitched chapters: a black box with the next
/// chapter's title, fixed at the middle of the box.
final class WebtoonEndCell: UICollectionViewCell {
    static let reuseID = "end"

    private let stack = UIStackView()
    private let caption = UILabel()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black

        caption.text = "NEXT CHAPTER"
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.textColor = UIColor.white.withAlphaComponent(0.5)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 3
        spinner.color = .white
        spinner.hidesWhenStopped = true

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        [caption, titleLabel, spinner].forEach(stack.addArrangedSubview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(title: String, loading: Bool) {
        titleLabel.text = title
        loading ? spinner.startAnimating() : spinner.stopAnimating()
        isAccessibilityElement = true
        accessibilityLabel = "Next chapter: \(title)"
    }
}
