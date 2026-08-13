import AppKit
import DropFlowCore

@MainActor
final class ShelfWindowController: NSWindowController {
    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
        let size = NSSize(width: 332, height: 200)
        let window = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "DropFlow"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        // Must be .clear: an opaque window background paints the full square frame, so the
        // content view's rounded corners sit on grey squares and the radius reads as fake.
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        // The panel is deliberately NOT draggable by its background: a layer-backed view overriding mouseDown and any
        // NSTextField(labelWithString:) both report mouseDownCanMoveWindow == true, so the rows and
        // their titles became window-drag handles and stole the file drag. The panel repositions
        // itself on every show anyway, so background dragging bought nothing.
        window.contentView = ShelfRootView(store: store)
        super.init(window: window)
        // Deliberately NOT clearing the shelf when the panel hides. Hiding it — via Cmd-Shift-Space, the
        // header's "Hide Shelf" button, or the menu's Toggle Shelf — used to destroy the shelf,
        // which is not what any of those three labels promise. Clearing now happens only from the
        // trash button and the Clear Shelf menu item.
        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange), name: .shelfStoreDidChange, object: store)
        resizeForCurrentMode(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showNearCursor() {
        // Items can be moved or deleted while the shelf is hidden, so re-resolve before showing.
        // ponytail: synchronous fileExists per item on the main thread; fine at shelf sizes (≤ dozens),
        // move to a background pass with a main-thread apply if it ever gets slow.
        store.refreshResolvedStates()
        guard let window else { return }
        resizeForCurrentMode(animated: false)
        positionNearCursor(window)
        window.orderFrontRegardless()
        // makeKey as well as makeFirstResponder. Ordering a panel front does not make it key, so
        // Escape/Delete/Cmd-A went to whatever app was frontmost — pressing Escape to dismiss the
        // shelf cancelled something in Safari while the shelf stayed open. This is safe precisely
        // because the panel is .nonactivatingPanel: it takes key status for keystrokes without
        // activating DropFlow, so the document the user was typing in keeps its insertion point.
        window.makeKey()
        // Borderless non-activating panels start with no first responder, so key events never reach
        // the content view's keyDown.
        window.makeFirstResponder(window.contentView)
    }

    func toggleNearCursor() {
        guard let window else { return }
        if window.isVisible {
            // Only the hide branch is guarded. While a mouse button is down the user is carrying files
            // toward the shelf, and taking the drop target away mid-drag is never what they meant.
            // Showing it mid-drag IS wanted — that is what shake activation is for — and gating the
            // whole function also risked a dead left-click on the menu bar icon, since the button's
            // action can dispatch while the OS still reports the button pressed.
            guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
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

        // Height only. The panel's real width is layout-determined (measured 367 pt in every mode),
        // so the old width targets of 332/360 never matched and the early-out never fired: every
        // store change ran an animated resize that changed nothing, and forcing the width back to
        // 332 blocked ~73 ms before layout pushed it to 367 again.
        let targetContentHeight = PanelMetrics.contentHeight(itemCount: store.items.count, mode: store.dragMode)

        let currentContentHeight = window.contentView?.bounds.height ?? 0
        guard abs(currentContentHeight - targetContentHeight) > 0.5 else { return }

        let targetContentRect = NSRect(x: 0, y: 0, width: window.frame.width, height: targetContentHeight)
        let targetFrameSize = window.frameRect(forContentRect: targetContentRect).size
        var frame = window.frame
        frame.origin.y += frame.height - targetFrameSize.height
        frame.size = targetFrameSize
        // Growing the panel keeps its top edge fixed, so a shelf summoned near the bottom of the
        // screen would walk its rows off-screen — and the background drag that used to rescue it
        // is gone. Same 12 pt inset as positionNearCursor.
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visibleFrame.minY + 12 {
            frame.origin.y = min(visibleFrame.minY + 12, visibleFrame.maxY - frame.height - 12)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animated && window.isVisible && !reduceMotion)
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
        if !isKeyWindow, event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}
