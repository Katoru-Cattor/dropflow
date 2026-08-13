import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ShelfStore()
    private var shelfWindowController: ShelfWindowController?
    private var statusBarController: StatusBarController?
    private var hotkeyController: HotkeyController?
    private var shakeDetector: ShakeDetector?
    private let updateController = UpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.load()

        let shelfWindowController = ShelfWindowController(store: store)
        self.shelfWindowController = shelfWindowController

        statusBarController = StatusBarController(store: store, actions: AppActions(
            toggleShelf: { [weak shelfWindowController] in shelfWindowController?.toggleNearCursor() },
            showShelf: { [weak shelfWindowController] in shelfWindowController?.showNearCursor() },
            requestAccessibility: { [weak self] in
                ShakeDetector.requestAccessibilityPermission()
                self?.shakeDetector?.start()
            },
            checkForUpdates: { [weak self] in self?.updateController.checkForUpdates() },
            quit: { NSApp.terminate(nil) }
        ))

        hotkeyController = HotkeyController { [weak shelfWindowController] in
            shelfWindowController?.toggleNearCursor()
        }
        hotkeyController?.start()

        shakeDetector = ShakeDetector {
            shelfWindowController.showNearCursor()
        }
        shakeDetector?.start()

        shelfWindowController.showNearCursor()
        updateController.checkInBackgroundIfDue()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.captureRecentSnapshotIfNeeded()
        store.save()
    }
}
