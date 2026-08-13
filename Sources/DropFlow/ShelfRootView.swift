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

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
        // .continuous is the squircle macOS itself uses; a plain circular arc is what makes a
        // panel corner look "off" next to real system windows.
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor

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
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 2
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
        let dragModeControl = ShelfSegmentedControl(
            labels: [ShelfDragMode.simplify.label, ShelfDragMode.advance.label],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeDragMode(_:))
        )
        dragModeControl.selectedSegment = store.dragMode == .simplify ? 0 : 1
        dragModeControl.controlSize = .small
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
        countLabel.stringValue = store.items.isEmpty ? "Ready" : "\(store.items.count) item\(store.items.count == 1 ? "" : "s")"
        emptyLabel.isHidden = !store.items.isEmpty

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
                let height = grid.preferredHeight(forWidth: max(scrollView.contentView.bounds.width, 320))
                grid.heightAnchor.constraint(equalToConstant: height).isActive = true
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
        store.clearShelf()
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

    init(store: ShelfStore) {
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
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        let items = Array(store.items.filter { $0.lastResolvedState != .missing }.prefix(12))
        for (index, item) in items.enumerated() {
            let preview = ShelfPreviewImageView(item: item, store: store, thumbnailSize: CGSize(width: 60, height: 60))
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

        if store.items.count > items.count {
            let more = NSTextField(labelWithString: "+\(store.items.count - items.count)")
            more.alignment = .center
            more.font = .systemFont(ofSize: 12, weight: .bold)
            more.textColor = .labelColor
            more.wantsLayer = true
            more.layer?.cornerRadius = 10
            more.layer?.masksToBounds = true
            more.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            more.translatesAutoresizingMaskIntoConstraints = false
            addSubview(more)

            let visibleCount = min(items.count, 11)
            let row = visibleCount / columns
            let column = visibleCount % columns
            NSLayoutConstraint.activate([
                more.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12 + CGFloat(column) * (tileSize + tileSpacing)),
                more.topAnchor.constraint(equalTo: topAnchor, constant: 12 + CGFloat(row) * (tileSize + tileSpacing)),
                more.widthAnchor.constraint(equalToConstant: tileSize),
                more.heightAnchor.constraint(equalToConstant: tileSize)
            ])
        }
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let visibleCount = min(max(store.items.count, 1), 12)
        let rows = Int(ceil(Double(visibleCount) / Double(columns)))
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
        context == .outsideApplication ? [.copy, .move] : .copy
    }

    private func makeDraggingItem(for item: ShelfItem, index: Int) -> NSDraggingItem? {
        let writer: NSPasteboardWriting
        if let url = store.resolveURL(for: item) {
            writer = url as NSURL
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
