import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class ShakeDetector {
    private let action: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var lastPoint: NSPoint?
    private var lastDirection: CGFloat = 0
    private var turns: [Date] = []
    private var lastActivation = Date.distantPast
    private var leftButtonWasDown = false
    private var dragPasteboardCountAtPress: Int = 0
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(action: @escaping () -> Void) {
        self.action = action
    }

    isolated deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        pollTimer?.invalidate()
    }

    func start() {
        stop()

        if Self.isAccessibilityTrusted {
            startEventTap()
        } else {
            startCursorPolling()
        }
    }

    private func startCursorPolling() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let isDragging = (NSEvent.pressedMouseButtons & 1) == 1
                self.handle(point: NSEvent.mouseLocation, isDragging: isDragging)
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startEventTap() {
        let mask =
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let detector = Unmanaged<ShakeDetector>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = detector.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                let point = event.location
                Task { @MainActor in
                    detector.handle(point: point, isDragging: true)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        lastPoint = nil
        lastDirection = 0
        turns.removeAll()
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        if isAccessibilityTrusted {
            showAccessibilityEnabled()
            return
        }

        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        showShakeEnabledWithFallback()
    }

    private static func showAccessibilityEnabled() {
        let alert = NSAlert()
        alert.messageText = "Shake Activation Is Enabled"
        alert.informativeText = "DropFlow is watching pointer movement and will open the shelf when you shake left and right while dragging."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showShakeEnabledWithFallback() {
        let alert = NSAlert()
        alert.messageText = "Shake Activation Is Enabled"
        alert.informativeText = "DropFlow can still detect the pointer shake without this permission. Accessibility only gives macOS an extra event stream for reliability."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func handle(point: NSPoint, isDragging: Bool) {
        defer {
            lastPoint = point
            leftButtonWasDown = isDragging
        }
        if isDragging && !leftButtonWasDown {
            dragPasteboardCountAtPress = dragPasteboard.changeCount
        }
        guard isDragging else {
            if lastDirection != 0 || !turns.isEmpty {
                lastDirection = 0
                turns.removeAll()
            }
            return
        }
        let currentDragCount = dragPasteboard.changeCount
        guard currentDragCount != dragPasteboardCountAtPress else {
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

        let cutoff = Date().addingTimeInterval(-0.85)
        turns = turns.filter { $0 > cutoff }

        guard turns.count >= 5, Date().timeIntervalSince(lastActivation) > 1.8 else { return }
        turns.removeAll()
        lastActivation = Date()
        action()
    }
}
