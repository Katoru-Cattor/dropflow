import AppKit

/// The 26×24 row button, shared by both row views. `ShelfRootView` keeps its own 30×26 variant on
/// purpose — different size, and it needs `ShelfIconButton`.
@MainActor
func shelfActionButton(symbol: String, accessibility: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) ?? NSImage(), target: target, action: action)
    button.bezelStyle = .texturedRounded
    button.isBordered = true
    button.toolTip = accessibility
    button.widthAnchor.constraint(equalToConstant: 26).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return button
}

/// Copying wrote to the pasteboard with no acknowledgement anywhere, so the click was indistinguishable
/// from a dead button. Flash a checkmark and put the glyph back.
@MainActor
func shelfFlashCopyConfirmation(on button: NSButton?) {
    guard let button else { return }
    // Restore the caller's own label, not a hardcoded "Copy": the stack row's button says
    // "Copy items", and hardcoding degraded its VoiceOver label permanently after one copy.
    let restoredLabel = button.image?.accessibilityDescription ?? button.toolTip ?? "Copy"
    button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak button] in
        MainActor.assumeIsolated {
            button?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: restoredLabel)
        }
    }
}

@MainActor
final class ShelfItemRowView: NSView, NSDraggingSource {
    private let item: ShelfItem
    private let store: ShelfStore
    private var didStartDrag = false
    private weak var copyButton: NSButton?
    // Selecting on drag rebuilds this row, which removes it from the panel while the drag is still
    // running. The session needs its source alive to report back, so the row holds itself until then.
    private var dragSessionHold: ShelfItemRowView?

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = store.selectedIDs.contains(item.id) ? 2 : 1

        let preview = ShelfPreviewImageView(item: item, store: store)
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.displayName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = item.lastResolvedState == .missing ? .systemRed : .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        // Names truncate in the middle in a ~367 pt panel and the detail line only ever names the type,
        // so the tooltip is the one place the full path is available.
        title.toolTip = locationText()
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

        let revealButton = shelfActionButton(symbol: "magnifyingglass", accessibility: "Reveal in Finder", target: self, action: #selector(revealItem))
        let openButton = shelfActionButton(symbol: "arrow.up.forward.app", accessibility: "Open", target: self, action: #selector(openItem))
        let copyButton = shelfActionButton(symbol: "doc.on.doc", accessibility: "Copy", target: self, action: #selector(copyItem))
        let removeButton = shelfActionButton(symbol: "minus.circle", accessibility: "Remove", target: self, action: #selector(removeItem))

        revealButton.isEnabled = canReveal
        openButton.isEnabled = canOpen
        copyButton.isEnabled = canCopy
        self.copyButton = copyButton

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

        applyLayerColors()
    }

    private func applyLayerColors() {
        // Layer colours are CGColor snapshots taken once, so without this the row keeps the palette it
        // was built in when the system flips between light and dark.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.cgColor
            layer?.borderColor = borderColor.cgColor
        }
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

    private var canReveal: Bool {
        item.isFileBacked && item.lastResolvedState == .resolved
    }

    private var canOpen: Bool {
        item.lastResolvedState != .missing
    }

    /// Mirrors what `copyValue(for:)` can actually put on the pasteboard, so the button is never live
    /// for an item that would copy nothing and flash a checkmark anyway.
    private var canCopy: Bool {
        store.resolveURL(for: item) != nil || item.inlineText != nil
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

    private func locationText() -> String {
        if let url = store.resolveURL(for: item) {
            return url.isFileURL ? url.path : url.absoluteString
        }
        return item.inlineText ?? item.displayName
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Without this, right-clicking a row did nothing at all, which reads as a broken row. It
        // deliberately leaves the selection alone: the menu acts on its own row, and selecting would
        // rebuild — and remove — the very view the menu is attached to.
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, Selector, Bool)] = [
            ("Reveal in Finder", #selector(revealItem), canReveal),
            ("Open", #selector(openItem), canOpen),
            ("Copy", #selector(copyItem), canCopy)
        ]
        for (title, action, enabled) in entries {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeItem), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func revealItem() { store.reveal(item) }
    @objc private func openItem() { store.open(item) }
    @objc private func removeItem() { store.remove(item) }

    @objc private func copyItem() {
        store.copyValue(for: item)
        shelfFlashCopyConfirmation(on: copyButton)
    }

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

        // Dragging an unselected row used to leave the previous rows highlighted while a different
        // icon flew, so the highlight and the payload disagreed on screen.
        if !store.selectedIDs.contains(item.id) {
            store.selectOnly(item)
        }

        let dragItems = store.itemsForDrag(startingWith: item)
        let draggingItems = dragItems.compactMap(makeDraggingItem(for:))
        guard !draggingItems.isEmpty else { return }

        dragSessionHold = self
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // .copy in both contexts. The payload is a file-url to the user's own file — the shelf stores
        // references, not copies — so advertising .move lets Finder relocate the original out of
        // ~/Downloads. Not gated on a modifier: in Finder, Command forces move and Option forces copy,
        // so a Command gate would match nothing.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSessionHold = nil
    }

    private func makeDraggingItem(for item: ShelfItem) -> NSDraggingItem? {
        let writer: NSPasteboardWriting
        if let url = store.resolveURL(for: item) {
            if url.isFileURL {
                writer = url as NSURL
            } else {
                // A web URL written as NSURL advertises only public.url, so plain-text drop targets
                // saw nothing — and copyValue already writes .string, so drag and copy disagreed
                // about the same item.
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                writer = pasteboardItem
            }
        } else if let text = item.inlineText {
            writer = text as NSString
        } else {
            return nil
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(
            draggingFrame(for: item),
            contents: ShelfPreviewImageView.fallbackImage(for: item, store: store)
        )
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
