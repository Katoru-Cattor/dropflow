import AppKit
@preconcurrency import QuickLookThumbnailing

@MainActor
final class ShelfPreviewImageView: NSImageView {
    private var representedItemID: UUID?

    init(item: ShelfItem, store: ShelfStore, thumbnailSize: CGSize = CGSize(width: 52, height: 52)) {
        super.init(frame: .zero)
        setup()
        configure(item: item, store: store, thumbnailSize: thumbnailSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
    }

    private func configure(item: ShelfItem, store: ShelfStore, thumbnailSize: CGSize) {
        representedItemID = item.id
        image = Self.fallbackImage(for: item, store: store)

        guard item.lastResolvedState != .missing,
              let url = store.resolveURL(for: item),
              url.isFileURL
        else { return }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: thumbnailSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let thumbnail else { return }
            DispatchQueue.main.async {
                guard self?.representedItemID == item.id else { return }
                self?.image = thumbnail.nsImage
            }
        }
    }

    static func fallbackImage(for item: ShelfItem, store: ShelfStore) -> NSImage {
        if item.lastResolvedState == .missing {
            return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Missing") ?? NSImage()
        }
        if let url = store.resolveURL(for: item), url.isFileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        switch item.kind {
        case .url:
            return NSImage(systemSymbolName: "link", accessibilityDescription: "URL") ?? NSImage()
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text") ?? NSImage()
        case .image:
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "Image") ?? NSImage()
        case .file, .folder, .unknown:
            return NSImage(systemSymbolName: "doc", accessibilityDescription: "Item") ?? NSImage()
        }
    }
}

@MainActor
final class ShelfStackPreviewView: NSView {
    private let items: [ShelfItem]
    private let store: ShelfStore

    init(items: [ShelfItem], store: ShelfStore) {
        self.items = items
        self.store = store
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true

        for (index, item) in Array(items.prefix(3)).reversed().enumerated() {
            let preview = ShelfPreviewImageView(item: item, store: store, thumbnailSize: CGSize(width: 44, height: 44))
            preview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(preview)

            let offset = CGFloat(index * 5)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: offset),
                preview.topAnchor.constraint(equalTo: topAnchor, constant: offset * 0.7),
                preview.widthAnchor.constraint(equalToConstant: 38),
                preview.heightAnchor.constraint(equalToConstant: 38)
            ])
        }

        let badge = NSTextField(labelWithString: "\(items.count)")
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = NSColor(calibratedWhite: 0.05, alpha: 1)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        badge.layer?.masksToBounds = true
        badge.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.96, blue: 0.54, alpha: 1).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 19),
            badge.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
}
