import AppKit

@MainActor
final class ShelfDropView: NSView {
    private let store: ShelfStore
    private var isDraggingInside = false {
        didSet { needsDisplay = true }
    }

    init(store: ShelfStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isInternalShelfDrag(sender) else {
            isDraggingInside = false
            return []
        }
        isDraggingInside = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDraggingInside = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isInternalShelfDrag(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDraggingInside = false
        guard !isInternalShelfDrag(sender) else { return false }
        store.addItems(from: sender.draggingPasteboard)
        return true
    }

    private func isInternalShelfDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let sourceView = sender.draggingSource as? NSView else { return false }
        return sourceView.window === window
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDraggingInside else { return }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}
