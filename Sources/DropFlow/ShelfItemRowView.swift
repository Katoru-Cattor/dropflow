import AppKit

@MainActor
final class ShelfItemRowView: NSView, NSDraggingSource {
    private let item: ShelfItem
    private let store: ShelfStore
    private var didStartDrag = false

    init(item: ShelfItem, store: ShelfStore) {
        self.item = item
        self.store = store
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderWidth = store.selectedIDs.contains(item.id) ? 2 : 1
        layer?.borderColor = borderColor.cgColor

        let preview = ShelfPreviewImageView(item: item, store: store)
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.displayName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = item.lastResolvedState == .missing ? .systemRed : .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: detailText())
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let revealButton = actionButton(symbol: "magnifyingglass", action: #selector(revealItem), accessibility: "Reveal in Finder")
        let openButton = actionButton(symbol: "arrow.up.forward.app", action: #selector(openItem), accessibility: "Open")
        let copyButton = actionButton(symbol: "doc.on.doc", action: #selector(copyItem), accessibility: "Copy")
        let removeButton = actionButton(symbol: "minus.circle", action: #selector(removeItem), accessibility: "Remove")

        revealButton.isEnabled = item.isFileBacked && item.lastResolvedState == .resolved
        openButton.isEnabled = item.lastResolvedState != .missing

        let buttons = NSStackView(views: [revealButton, openButton, copyButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(preview)
        addSubview(labels)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 52),
            preview.heightAnchor.constraint(equalToConstant: 52),

            labels.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private var backgroundColor: NSColor {
        if store.selectedIDs.contains(item.id) {
            return NSColor.controlAccentColor.withAlphaComponent(0.18)
        }
        return NSColor.controlBackgroundColor.withAlphaComponent(0.78)
    }

    private var borderColor: NSColor {
        if store.selectedIDs.contains(item.id) {
            return .controlAccentColor
        }
        if item.lastResolvedState == .missing {
            return .systemRed.withAlphaComponent(0.7)
        }
        return .separatorColor
    }

    private func detailText() -> String {
        if item.lastResolvedState == .missing {
            return "\(item.kind.label) unavailable"
        }
        if let url = store.resolveURL(for: item) {
            if url.isFileURL {
                if let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]),
                   let description = values.localizedTypeDescription {
                    return description
                }
                return item.kind.label
            }
            return url.host ?? "Link"
        }
        if item.inlineText != nil {
            return "Text snippet"
        }
        return item.kind.label
    }

    private func actionButton(symbol: String, action: Selector, accessibility: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.toolTip = accessibility
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func revealItem() { store.reveal(item) }
    @objc private func openItem() { store.open(item) }
    @objc private func copyItem() { store.copyValue(for: item) }
    @objc private func removeItem() { store.remove(item) }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        guard !didStartDrag else { return }
        if event.modifierFlags.contains(.command) {
            store.toggleSelection(for: item)
        } else {
            store.selectOnly(item)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, item.lastResolvedState != .missing else { return }
        didStartDrag = true

        let dragItems = store.itemsForDrag(startingWith: item)
        let draggingItems = dragItems.compactMap(makeDraggingItem(for:))
        guard !draggingItems.isEmpty else { return }

        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }

    private func makeDraggingItem(for item: ShelfItem) -> NSDraggingItem? {
        let writer: NSPasteboardWriting
        let image: NSImage

        if let url = store.resolveURL(for: item) {
            writer = url as NSURL
            image = ShelfPreviewImageView.fallbackImage(for: item, store: store)
        } else if let text = item.inlineText {
            writer = text as NSString
            image = ShelfPreviewImageView.fallbackImage(for: item, store: store)
        } else {
            return nil
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(draggingFrame(for: item), contents: image)
        return draggingItem
    }

    private func draggingFrame(for dragItem: ShelfItem) -> NSRect {
        let dragItems = store.itemsForDrag(startingWith: item)
        guard let index = dragItems.firstIndex(where: { $0.id == dragItem.id }) else {
            return NSRect(x: 8, y: 8, width: 42, height: 42)
        }
        return NSRect(x: 8 + min(index, 4) * 4, y: 8 + min(index, 4) * 4, width: 42, height: 42)
    }
}
