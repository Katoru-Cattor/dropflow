import AppKit
import DropFlowCore

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
            checkForUpdates: { [weak self] in self?.updateController.checkForUpdates() },
            // Read lazily: the hotkey is registered below, after this controller exists.
            hotkeyStatus: { [weak self] in self?.hotkeyController?.lastRegistrationStatus ?? noErr },
            quit: { NSApp.terminate(nil) }
        ))

        hotkeyController = HotkeyController { [weak shelfWindowController] in
            shelfWindowController?.toggleNearCursor()
        }
        hotkeyController?.start()

        shakeDetector = ShakeDetector { [weak shelfWindowController] in
            // Shake must only ever summon a hidden shelf, never re-position a visible one. The
            // detector's drag gate cannot tell our own beginDraggingSession from a Finder drag, so
            // shaking while dragging items OUT of the shelf would teleport the panel under the
            // pointer — and the drop then lands back on the shelf and is rejected as internal.
            guard shelfWindowController?.window?.isVisible != true else { return }
            shelfWindowController?.showNearCursor()
        }
        shakeDetector?.start()

        // Show the shelf on first launch only. This is an LSUIElement app, so with nothing shown a
        // new user sees no evidence it installed; but it also offers Launch at Login, and every
        // later launch is a login — a .floating, canJoinAllSpaces panel that never resigns key
        // must not land on top of whatever the user is doing at boot.
        if !UserDefaults.standard.bool(forKey: "HasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
            shelfWindowController.showNearCursor()
        }
        updateController.checkInBackgroundIfDue()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.captureRecentSnapshotIfNeeded()
        store.saveNow()
    }
}
