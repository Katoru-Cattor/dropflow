import AppKit

@MainActor
final class ShelfWindowController: NSWindowController {
    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
        let size = NSSize(width: 390, height: 440)
        let window = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DropFlow"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = ShelfRootView(store: store)
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange), name: .shelfStoreDidChange, object: store)
        resizeForCurrentMode(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showNearCursor() {
        guard let window else { return }
        resizeForCurrentMode(animated: false)
        positionNearCursor(window)
        window.orderFrontRegardless()
    }

    func toggleNearCursor() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showNearCursor()
        }
    }

    @objc private func storeDidChange() {
        resizeForCurrentMode(animated: true)
    }

    private func resizeForCurrentMode(animated: Bool) {
        guard let window else { return }

        let targetContentSize: NSSize
        if store.dragMode == .simplify, !store.items.isEmpty {
            let rows = max(1, Int(ceil(Double(min(store.items.count, 12)) / 4.0)))
            let contentHeight = 76 + CGFloat(rows) * 58 + CGFloat(max(rows - 1, 0)) * 10 + 34
            targetContentSize = NSSize(width: 332, height: min(max(contentHeight, 188), 330))
        } else {
            targetContentSize = NSSize(width: 390, height: 440)
        }

        let currentContentSize = window.contentView?.bounds.size ?? .zero
        guard abs(currentContentSize.width - targetContentSize.width) > 0.5 || abs(currentContentSize.height - targetContentSize.height) > 0.5 else {
            return
        }

        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
        var frame = window.frame
        frame.origin.y += frame.height - targetFrameSize.height
        frame.size = targetFrameSize
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    private func positionNearCursor(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = window.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 16)

        if origin.x < visibleFrame.minX + 12 {
            origin.x = visibleFrame.minX + 12
        }
        if origin.x + size.width > visibleFrame.maxX - 12 {
            origin.x = visibleFrame.maxX - size.width - 12
        }
        if origin.y < visibleFrame.minY + 12 {
            origin.y = min(mouse.y + 16, visibleFrame.maxY - size.height - 12)
        }

        window.setFrameOrigin(origin)
    }
}

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}
