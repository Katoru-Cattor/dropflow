import AppKit
import CoreGraphics

@MainActor
final class ShakeDetector {
    private let action: () -> Void
    private var pollTimer: Timer?
    private var lastPoint: NSPoint?
    private var lastDirection: CGFloat = 0
    private var turns: [Date] = []
    private var lastActivation = Date.distantPast
    private var dragPasteboardCountWhenIdle: Int = 0
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(action: @escaping () -> Void) {
        self.action = action
    }

    isolated deinit {
        pollTimer?.invalidate()
    }

    /// Whether the pointer poll is actually live, so the status menu can never claim shake
    /// activation is armed while nothing is watching the pointer.
    var isWatching: Bool {
        pollTimer?.isValid == true
    }

    func start() {
        stop()
        // Pointer polling only, deliberately. The CGEvent tap this replaced needed
        // Accessibility (false on a stock machine, so it silently never fired) and its
        // drag-only event mask could not see the press edge, which latched the gate below
        // open for the process lifetime. NSEvent.mouseLocation needs no permission at all,
        // so shake activation now works on first launch with nothing for the user to grant.
        // Baseline the drag pasteboard now, not from zero: the live .drag changeCount is always
        // above zero mid-session, so starting at 0 leaves the "a drag is in flight" gate open. If
        // the app launched with a button already held, a horizontal wiggle would open the shelf.
        dragPasteboardCountWhenIdle = dragPasteboard.changeCount
        startCursorPolling()
        NSLog("DropFlow: shake detection armed (pointer polling, no permission required)")
    }

    private func startCursorPolling() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let isDragging = (NSEvent.pressedMouseButtons & 1) == 1
                self.handle(point: NSEvent.mouseLocation, isDragging: isDragging)
            }
        }
        // Without a tolerance the timer opts the whole process out of kernel timer coalescing and
        // App Nap, so 30 exact wakeups a second cost ~0.23% of a core while completely idle. 50 ms
        // of slack lets the kernel batch them; the gesture is far too slow to notice the jitter.
        timer.tolerance = 0.05
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastPoint = nil
        lastDirection = 0
        turns.removeAll()
    }

    private func handle(point: NSPoint, isDragging: Bool) {
        defer { lastPoint = point }

        guard isDragging else {
            // Re-baseline the drag pasteboard on every idle tick instead of on the press
            // edge: with timer tolerance the press can be observed up to ~80 ms late, and a
            // snapshot taken after AppKit already wrote the drag pasteboard would compare
            // equal in the gate below, killing the shake for that entire drag.
            dragPasteboardCountWhenIdle = dragPasteboard.changeCount
            if lastDirection != 0 || !turns.isEmpty {
                lastDirection = 0
                turns.removeAll()
            }
            return
        }

        // A real drag writes the drag pasteboard; a marquee selection or a held button does
        // not. Without this gate any button-held oscillation would open the shelf.
        guard dragPasteboard.changeCount != dragPasteboardCountWhenIdle else {
            if lastDirection != 0 || !turns.isEmpty {
                lastDirection = 0
                turns.removeAll()
            }
            return
        }
        guard let previous = lastPoint else { return }

        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let distance = hypot(dx, dy)
        guard distance > 7, abs(dx) > abs(dy) * 1.45 else { return }

        let direction: CGFloat = dx > 0 ? 1 : -1
        if lastDirection != 0, direction != lastDirection {
            turns.append(Date())
        }
        lastDirection = direction

        // 4 reversals in 1.2 s ≈ 2.5 reversals/s: a deliberate ~1.7 Hz oscillation. The
        // turnaround sample is where pointer speed is lowest, so it often fails the 7 pt
        // step above and goes uncounted — a tighter window makes the gesture unhittable.
        let cutoff = Date().addingTimeInterval(-1.2)
        turns = turns.filter { $0 > cutoff }

        guard turns.count >= 4, Date().timeIntervalSince(lastActivation) > 1.8 else { return }
        turns.removeAll()
        lastActivation = Date()
        NSLog("DropFlow: shake detected during a drag, opening the shelf")
        action()
    }
}
