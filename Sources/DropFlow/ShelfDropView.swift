import AppKit
import DropFlowCore

@MainActor
final class ShelfDropView: NSView {
    private let store: ShelfStore
    private var isDraggingInside = false {
        didSet { needsDisplay = true }
    }

    init(store: ShelfStore) {
        self.store = store
        super.init(frame: .zero)
        // Photos, Mail attachments and some browser drags offer only a file promise — no file URL,
        // no image data. Without these types the shelf refuses the drag outright: no highlight, no
        // drop, no explanation.
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff] + promiseTypes)
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

        let before = store.items.count
        store.addItems(from: sender.draggingPasteboard)
        if store.items.count > before { return true }
        if receivePromisedFiles(from: sender.draggingPasteboard) { return true }
        // Blank text, or a row the shelf already holds. Reporting the truth makes the drag spring
        // back to where it came from instead of animating a success that added nothing.
        return false
    }

    /// Materialises file promises and re-enters through the pasteboard path, so promised files get
    /// the same bookmark, de-dupe and persistence treatment as a Finder drag.
    private func receivePromisedFiles(from pasteboard: NSPasteboard) -> Bool {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]
        guard let receivers, !receivers.isEmpty else { return false }

        // ponytail: promised files land in the temp directory, so a shelved Photos drag can go stale
        // if macOS purges it. Upgrade path: write them into the store's support directory once
        // ShelfStore exposes it.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("DropFlow-Drops", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            NSLog("DropFlow drop error: no promise destination: \(error.localizedDescription)")
            return false
        }

        let store = self.store
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: Self.promiseQueue) { url, error in
                if let error {
                    // ponytail: Console only. performDragOperation already returned true — springing
                    // the drag back mid-async is worse — so a failed Photos export animates an
                    // accepted drop onto an unchanged shelf. Upgrade: give ShelfStore an error
                    // channel the panel can surface, and report it here.
                    NSLog("DropFlow drop error: promised file failed: \(error.localizedDescription)")
                    return
                }
                Task { @MainActor in
                    let scratch = NSPasteboard.withUniqueName()
                    scratch.clearContents()
                    scratch.writeObjects([url as NSURL])
                    store.addItems(from: scratch)
                    scratch.releaseGlobally()
                }
            }
        }
        return true
    }

    /// The promise reader must not be handed the main queue.
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.katoru-cattor.dropflow.file-promises"
        return queue
    }()

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
