import AppKit

@MainActor
final class ShelfRootView: NSView {
    private let store: ShelfStore
    private let dropView: ShelfDropView
    private let headerLabel = NSTextField(labelWithString: "DropFlow")
    private let countLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Drop files, folders, URLs, text, or images here")
    private let scrollView = NSScrollView()
    private var zipButton: NSButton?
    private var clearButton: NSButton?
    private var rowKeySequence: [String] = []
    private var rowViewsByKey: [String: NSView] = [:]
    private var lastDragMode: ShelfDragMode?
    private var rebuildScheduled = false

    init(store: ShelfStore) {
        self.store = store
        self.dropView = ShelfDropView(store: store)
        super.init(frame: .zero)
        setup()
        rebuildRows()
        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange), name: .shelfStoreDidChange, object: store)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    /// A CGColor is a resolved snapshot, so every layer colour has to be re-derived on an
    /// appearance flip. Row views get this for free by being rebuilt; the root border does not.
    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
        // .continuous is the squircle macOS itself uses; a plain circular arc is what makes a
        // panel corner look "off" next to real system windows.
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyLayerColors()

        // No layer backgroundColor here: the vibrancy view below is the fill. A 94%-opaque
        // colour on top of it cancelled the blur it was paying for.
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffect)

        dropView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropView)

        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(header)

        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // Legacy scrollers reserve a permanent gutter, so an empty shelf showed a scrollbar
        // track with nothing to scroll. Overlay scrollers appear only while scrolling.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        // The panel is ~367 pt wide, so the first line already wraps; an unlimited line count plus
        // an explicit wrap width is what keeps the shortcut hint from being clipped.
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.preferredMaxLayoutWidth = 300
        emptyLabel.attributedStringValue = Self.emptyStateText()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),

            dropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropView.topAnchor.constraint(equalTo: topAnchor),
            dropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            header.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 40),

            scrollView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -10),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: dropView.leadingAnchor, constant: 28),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: dropView.trailingAnchor, constant: -28)
        ])
    }

    // The empty shelf is the only surface with room for the hint, so it carries the shortcut.
    // ponytail: the shortcut is spelled out here rather than read back from the HotkeyKeyCode /
    // HotkeyModifiers defaults, so a user who rebinds the hotkey sees a stale hint.
    private static func emptyStateText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        let text = NSMutableAttributedString(
            string: "Drop files, folders, URLs, text, or images here\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        text.append(NSAttributedString(
            string: "⌘⇧Space opens the shelf anywhere — or shake while dragging",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
        return text
    }

    private func makeHeader() -> NSView {
        let view = NSView()

        headerLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let zipButton = iconButton(symbol: "archivebox", action: #selector(zipItems), accessibility: "Create ZIP")
        let clearButton = iconButton(symbol: "trash", action: #selector(clearShelf), accessibility: "Clear Shelf")
        let closeButton = iconButton(symbol: "xmark", action: #selector(closeWindow), accessibility: "Hide Shelf")
        self.zipButton = zipButton
        self.clearButton = clearButton
        let dragModeControl = ShelfSegmentedControl(
            labels: [ShelfDragMode.simplify.label, ShelfDragMode.advance.label],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeDragMode(_:))
        )
        dragModeControl.selectedSegment = store.dragMode == .simplify ? 0 : 1
        dragModeControl.controlSize = .small
        // The mode names alone don't say that Simplify drags the shelf as one payload, which is the
        // whole difference between them.
        dragModeControl.setToolTip("Simplify — dragging any tile drags the whole shelf together", forSegment: 0)
        dragModeControl.setToolTip("Advance — drag items or your selection individually", forSegment: 1)
        dragModeControl.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [zipButton, clearButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLabel)
        view.addSubview(countLabel)
        view.addSubview(dragModeControl)
        view.addSubview(buttons)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor),
            countLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 1),

            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            dragModeControl.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
            dragModeControl.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            dragModeControl.widthAnchor.constraint(equalToConstant: 138),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: dragModeControl.leadingAnchor, constant: -10)
        ])

        return view
    }

    private func iconButton(symbol: String, action: Selector, accessibility: String) -> NSButton {
        let button = ShelfIconButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        button.toolTip = accessibility
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func storeDidChange() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.rebuildScheduled = false
                self.rebuildRows()
            }
        }
    }

    private func rebuildRows() {
        countLabel.stringValue = subtitle()
        emptyLabel.isHidden = !store.items.isEmpty
        // A button that looks live but can do nothing is the same defect twice: ZIP with no
        // file-backed item produced no window, no alert, no log line.
        // ...and file-backed is not enough: zipSelectedOrAll filters on the file still existing, so a
        // shelf of items whose originals were deleted left the button live and did nothing at all.
        zipButton?.isEnabled = store.items.contains { $0.isFileBacked && $0.lastResolvedState != .missing }
        clearButton?.isEnabled = !store.items.isEmpty

        let modeChanged = lastDragMode != store.dragMode
        lastDragMode = store.dragMode

        if store.dragMode == .simplify, !store.items.isEmpty {
            scrollView.hasVerticalScroller = false
            // Unconditional, and BEFORE the insert. The grid reads store.items once during its own
            // init, so a cached instance can never show a later drop; and invalidating afterwards
            // tore out the grid that had just been inserted, leaving a panel sized for N items with
            // nothing in it. There is only ever one grid view, so rebuilding it costs nothing.
            invalidateRowCache()
            applyRows(keys: ["simplify-grid"]) { _ in
                let grid = ShelfSimplifyGridView(store: store)
                grid.heightAnchor.constraint(equalToConstant: grid.preferredHeight()).isActive = true
                return grid
            }
            return
        }

        scrollView.hasVerticalScroller = true
        let groups = store.displayGroups()
        var keys: [String] = []
        keys.reserveCapacity(groups.count)
        var groupByKey: [String: ShelfDisplayGroup] = [:]
        for group in groups {
            let key = rowKey(for: group)
            keys.append(key)
            groupByKey[key] = group
        }

        if modeChanged { invalidateRowCache() }

        applyRows(keys: keys) { key in
            guard let group = groupByKey[key] else { return NSView() }
            let row: NSView = group.isStack
                ? ShelfStackRowView(group: group, store: store)
                : ShelfItemRowView(item: group.items[0], store: store)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
            return row
        }
    }

    /// "Ready" said nothing. Blank when empty (the empty-state label is already talking), and when
    /// items are missing say so — that is the only explanation for a shelf showing fewer than it holds.
    private func subtitle() -> String {
        guard !store.items.isEmpty else { return "" }
        let count = store.items.count
        var text = "\(count) item\(count == 1 ? "" : "s")"
        let missing = store.items.filter { $0.lastResolvedState == .missing }.count
        if missing > 0 { text += " · \(missing) missing" }
        return text
    }

    private func rowKey(for group: ShelfDisplayGroup) -> String {
        if group.isStack {
            let selected = store.selectedIDs.intersection(group.items.map(\.id)).count > 0 ? "1" : "0"
            return "stack-\(group.id.uuidString)-\(group.items.count)-\(selected)"
        }
        let item = group.items[0]
        let selected = store.selectedIDs.contains(item.id) ? "1" : "0"
        return "item-\(item.id.uuidString)-\(item.lastResolvedState.rawValue)-\(selected)"
    }

    private func applyRows(keys: [String], makeRow: (String) -> NSView) {
        let existing = Set(rowKeySequence)
        let desired = Set(keys)

        for key in existing.subtracting(desired) {
            if let view = rowViewsByKey.removeValue(forKey: key) {
                stackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }

        for (index, key) in keys.enumerated() {
            let view: NSView
            if let cached = rowViewsByKey[key] {
                view = cached
            } else {
                view = makeRow(key)
                rowViewsByKey[key] = view
            }
            if index < stackView.arrangedSubviews.count, stackView.arrangedSubviews[index] === view {
                continue
            }
            if view.superview === stackView {
                stackView.removeArrangedSubview(view)
            }
            stackView.insertArrangedSubview(view, at: index)
        }

        rowKeySequence = keys
    }

    private func invalidateRowCache() {
        for view in rowViewsByKey.values {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViewsByKey.removeAll()
        rowKeySequence.removeAll()
    }

    @objc private func changeDragMode(_ sender: NSSegmentedControl) {
        store.setDragMode(sender.selectedSegment == 0 ? .simplify : .advance)
    }

    @objc private func clearShelf() {
        let count = store.items.count
        if count > 1 {
            // Load-bearing: the app is .accessory behind a non-activating panel, so without this the
            // alert opens behind the frontmost app and the click looks like it did nothing.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Clear \(count) items from the shelf?"
            alert.informativeText = "Your files stay where they are. The shelf is kept in Recent Shelves in the menu bar, so you can put it back."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.clearShelf()
    }

    override func cancelOperation(_ sender: Any?) {
        window?.orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        // Escape: a plain NSView never routes a key event through to cancelOperation on its own.
        if event.keyCode == 53 {
            window?.orderOut(nil)
            return
        }
        if event.specialKey == .delete || event.specialKey == .deleteForward {
            removeSelection()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // An .accessory app has no main menu, so Cmd-A has nothing else to reach.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "a", !store.items.isEmpty,
              store.dragMode == .advance else {
            return super.performKeyEquivalent(with: event)
        }
        store.selectOnly(store.items)
        return true
    }

    /// Removes shelf references only — the files stay on disk — so this needs no confirmation.
    /// The beep is the native "that did nothing" answer when the selection is empty.
    private func removeSelection() {
        // Simplify draws no selection ring, so a selection made in Advance is invisible there —
        // deleting it on a keypress would look like the shelf losing items on its own.
        let selected = store.dragMode == .advance ? store.items.filter { store.selectedIDs.contains($0.id) } : []
        guard !selected.isEmpty else {
            NSSound.beep()
            return
        }
        store.remove(selected)
    }

    @objc private func zipItems() {
        store.zipSelectedOrAll()
    }

    @objc private func closeWindow() {
        window?.orderOut(nil)
    }
}

private final class ShelfIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class ShelfSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class ShelfSimplifyGridView: NSView, NSDraggingSource {
    private let store: ShelfStore
    private var didStartDrag = false
    private let columns = 4
    private let tileSize: CGFloat = 58
    private let tileSpacing: CGFloat = 10
    /// Tiles, badge count and panel height all read these two, so they cannot disagree.
    private let visibleItems: [ShelfItem]
    private let hiddenCount: Int
    private var moreBadge: NSTextField?

    init(store: ShelfStore) {
        self.store = store
        let present = store.items.filter { $0.lastResolvedState != .missing }
        // Past a full grid the last cell belongs to the "+N" badge, not to a 12th thumbnail —
        // otherwise the badge is laid out on top of it.
        let shown = Array(present.prefix(present.count > 12 ? 11 : 12))
        self.visibleItems = shown
        // Counted against the filtered list: items whose file has gone are not "more items",
        // and promising them was a promise of files that no longer exist.
        self.hiddenCount = present.count - shown.count
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

    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
            moreBadge?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        for (index, item) in visibleItems.enumerated() {
            let preview = ShelfPreviewImageView(item: item, store: store, thumbnailSize: CGSize(width: 60, height: 60))
            preview.toolTip = item.displayName
            preview.setAccessibilityLabel(item.displayName)
            preview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(preview)

            let row = index / columns
            let column = index % columns
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12 + CGFloat(column) * (tileSize + tileSpacing)),
                preview.topAnchor.constraint(equalTo: topAnchor, constant: 12 + CGFloat(row) * (tileSize + tileSpacing)),
                preview.widthAnchor.constraint(equalToConstant: tileSize),
                preview.heightAnchor.constraint(equalToConstant: tileSize)
            ])
        }

        if hiddenCount > 0 {
            let more = NSTextField(labelWithString: "+\(hiddenCount)")
            more.alignment = .center
            more.font = .systemFont(ofSize: 12, weight: .bold)
            more.textColor = .labelColor
            more.wantsLayer = true
            more.layer?.cornerRadius = 10
            more.layer?.masksToBounds = true
            more.toolTip = "\(hiddenCount) more item\(hiddenCount == 1 ? "" : "s") on the shelf"
            more.translatesAutoresizingMaskIntoConstraints = false
            addSubview(more)
            moreBadge = more

            let cell = visibleItems.count
            let row = cell / columns
            let column = cell % columns
            NSLayoutConstraint.activate([
                more.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12 + CGFloat(column) * (tileSize + tileSpacing)),
                more.topAnchor.constraint(equalTo: topAnchor, constant: 12 + CGFloat(row) * (tileSize + tileSpacing)),
                more.widthAnchor.constraint(equalToConstant: tileSize),
                more.heightAnchor.constraint(equalToConstant: tileSize)
            ])
        }

        applyLayerColors()
    }

    func preferredHeight() -> CGFloat {
        let cells = max(visibleItems.count + (hiddenCount > 0 ? 1 : 0), 1)
        let rows = Int(ceil(Double(cells) / Double(columns)))
        return 24 + CGFloat(rows) * tileSize + CGFloat(max(rows - 1, 0)) * tileSpacing
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag else { return }
        didStartDrag = true

        // The grid can outlive the items it was built from by one run-loop turn after a clear,
        // so this must not subscript store.items.
        guard let first = store.items.first else { return }
        let draggingItems = store.itemsForDrag(startingWith: first)
            .enumerated()
            .compactMap { makeDraggingItem(for: $0.element, index: $0.offset) }
        guard !draggingItems.isEmpty else { return }

        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // .copy in both contexts. The payload is a file-url to the user's own file — the shelf stores
        // references, not copies — so advertising .move lets Finder relocate the original out of
        // ~/Downloads. Not gated on a modifier: in Finder, Command forces move and Option forces copy,
        // so a Command gate would match nothing.
        .copy
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
        let offset = min(index, 8) * 4
        draggingItem.setDraggingFrame(
            NSRect(x: 18 + offset, y: 18 + offset, width: 52, height: 52),
            contents: ShelfPreviewImageView.fallbackImage(for: item, store: store)
        )
        return draggingItem
    }
}
