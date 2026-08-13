import AppKit

@MainActor
final class ShelfStackRowView: NSView, NSDraggingSource {
    private let group: ShelfDisplayGroup
    private let store: ShelfStore
    private var didStartDrag = false
    private weak var copyButton: NSButton?
    // Selecting on drag rebuilds this row, which removes it from the panel while the drag is still
    // running. The session needs its source alive to report back, so the row holds itself until then.
    private var dragSessionHold: ShelfStackRowView?

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = store.selectedIDs.intersection(group.items.map(\.id)).isEmpty ? 1 : 2

        let preview = ShelfStackPreviewView(items: group.items, store: store)
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        // The title only has room for the first few names, so the tooltip is the only place the whole
        // stack can be identified.
        title.toolTip = group.items.map(\.displayName).joined(separator: "\n")
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

        let revealButton = shelfActionButton(symbol: "magnifyingglass", accessibility: "Reveal first item", target: self, action: #selector(revealFirstItem))
        let openButton = shelfActionButton(symbol: "arrow.up.forward.app", accessibility: "Open first item", target: self, action: #selector(openFirstItem))
        let copyButton = shelfActionButton(symbol: "doc.on.doc", accessibility: "Copy items", target: self, action: #selector(copyItems))
        let removeButton = shelfActionButton(symbol: "minus.circle", accessibility: "Remove stack", target: self, action: #selector(removeItems))

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
            preview.widthAnchor.constraint(equalToConstant: 54),
            preview.heightAnchor.constraint(equalToConstant: 50),

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

    /// The names carry the identity, so they own the title line. "N items" was true of every stack and
    /// made distinct stacks read as identical rows.
    private var titleText: String {
        group.items.prefix(3).map(\.displayName).joined(separator: ", ")
    }

    private var detailText: String {
        var text = "\(group.items.count) items"
        let missing = group.items.filter { $0.lastResolvedState == .missing }.count
        if missing > 0 {
            text += " · \(missing) unavailable"
        }
        return text
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

    private var canReveal: Bool {
        group.items.contains { $0.isFileBacked && $0.lastResolvedState == .resolved }
    }

    private var canOpen: Bool {
        group.items.contains { $0.lastResolvedState != .missing }
    }

    /// Mirrors what `copyValues(for:)` can actually put on the pasteboard, so the button is never live
    /// for a stack that would copy nothing and flash a checkmark anyway.
    private var canCopy: Bool {
        group.items.contains { store.resolveURL(for: $0) != nil || $0.inlineText != nil }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Without this, right-clicking a row did nothing at all, which reads as a broken row. It
        // deliberately leaves the selection alone: the menu acts on its own row, and selecting would
        // rebuild — and remove — the very view the menu is attached to. Ungroup is here as well as on
        // double-click because a gesture nothing advertises is a gesture nobody finds.
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, Selector, Bool)] = [
            ("Reveal First in Finder", #selector(revealFirstItem), canReveal),
            ("Open First Item", #selector(openFirstItem), canOpen),
            ("Copy Items", #selector(copyItems), canCopy),
            ("Ungroup", #selector(ungroupItems), true)
        ]
        for (title, action, enabled) in entries {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Stack", action: #selector(removeItems), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
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
        shelfFlashCopyConfirmation(on: copyButton)
    }

    @objc private func removeItems() {
        store.remove(group.items)
    }

    @objc private func ungroupItems() {
        store.ungroup(group)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        guard !didStartDrag else { return }
        // Splitting the stack is the only route to a single member: until it is ungrouped, an item
        // inside it cannot be dragged out, removed or opened on its own.
        if event.clickCount == 2 {
            store.ungroup(group)
            return
        }
        store.selectOnly(group.items)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag else { return }
        didStartDrag = true

        // Dragging an unselected row used to leave the previous rows highlighted while different
        // icons flew, so the highlight and the payload disagreed on screen.
        if store.selectedIDs.intersection(group.items.map(\.id)).isEmpty {
            store.selectOnly(group.items)
        }

        let dragItems = store.itemsForDrag(startingWith: group)
        let draggingItems = dragItems
            .enumerated()
            .compactMap { makeDraggingItem(for: $0.element, index: $0.offset) }
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

    private func makeDraggingItem(for item: ShelfItem, index: Int) -> NSDraggingItem? {
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
        let offset = min(index, 5) * 4
        draggingItem.setDraggingFrame(
            NSRect(x: 8 + offset, y: 8 + offset, width: 42, height: 42),
            contents: ShelfPreviewImageView.fallbackImage(for: item, store: store)
        )
        return draggingItem
    }
}
