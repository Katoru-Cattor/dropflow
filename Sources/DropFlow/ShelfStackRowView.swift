import AppKit

@MainActor
final class ShelfStackRowView: NSView, NSDraggingSource {
    private let group: ShelfDisplayGroup
    private let store: ShelfStore
    private var didStartDrag = false

    init(group: ShelfDisplayGroup, store: ShelfStore) {
        self.group = group
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
        layer?.borderWidth = store.selectedIDs.intersection(group.items.map(\.id)).isEmpty ? 1 : 2
        layer?.borderColor = borderColor.cgColor

        let preview = ShelfStackPreviewView(items: group.items, store: store)
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: detailText)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let revealButton = actionButton(symbol: "magnifyingglass", action: #selector(revealFirstItem), accessibility: "Reveal first item")
        let openButton = actionButton(symbol: "arrow.up.forward.app", action: #selector(openFirstItem), accessibility: "Open first item")
        let copyButton = actionButton(symbol: "doc.on.doc", action: #selector(copyItems), accessibility: "Copy items")
        let removeButton = actionButton(symbol: "minus.circle", action: #selector(removeItems), accessibility: "Remove stack")

        revealButton.isEnabled = group.items.contains { $0.isFileBacked && $0.lastResolvedState == .resolved }
        openButton.isEnabled = group.items.contains { $0.lastResolvedState != .missing }

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
            preview.widthAnchor.constraint(equalToConstant: 54),
            preview.heightAnchor.constraint(equalToConstant: 50),

            labels.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private var titleText: String {
        "\(group.items.count) items"
    }

    private var detailText: String {
        let missing = group.items.filter { $0.lastResolvedState == .missing }.count
        if missing > 0 {
            return "\(missing) unavailable"
        }
        return group.items.prefix(3).map(\.displayName).joined(separator: ", ")
    }

    private var backgroundColor: NSColor {
        store.selectedIDs.intersection(group.items.map(\.id)).isEmpty
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.78)
            : NSColor.controlAccentColor.withAlphaComponent(0.18)
    }

    private var borderColor: NSColor {
        if !store.selectedIDs.intersection(group.items.map(\.id)).isEmpty {
            return .controlAccentColor
        }
        if group.items.contains(where: { $0.lastResolvedState == .missing }) {
            return .systemRed.withAlphaComponent(0.7)
        }
        return .separatorColor
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

    @objc private func revealFirstItem() {
        guard let item = group.items.first(where: { $0.isFileBacked && $0.lastResolvedState == .resolved }) else { return }
        store.reveal(item)
    }

    @objc private func openFirstItem() {
        guard let item = group.items.first(where: { $0.lastResolvedState != .missing }) else { return }
        store.open(item)
    }

    @objc private func copyItems() {
        store.copyValues(for: group.items)
    }

    @objc private func removeItems() {
        store.remove(group.items)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        guard !didStartDrag else { return }
        store.selectOnly(group.items)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag else { return }
        didStartDrag = true

        let dragItems = store.itemsForDrag(startingWith: group)
        let draggingItems = dragItems
            .enumerated()
            .compactMap { makeDraggingItem(for: $0.element, index: $0.offset) }
        guard !draggingItems.isEmpty else { return }

        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }

    private func makeDraggingItem(for item: ShelfItem, index: Int) -> NSDraggingItem? {
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
        let offset = min(index, 5) * 4
        draggingItem.setDraggingFrame(NSRect(x: 8 + offset, y: 8 + offset, width: 42, height: 42), contents: image)
        return draggingItem
    }
}
