import AppKit
import DropFlowCore

struct AppActions {
    var toggleShelf: () -> Void
    var showShelf: () -> Void
    var checkForUpdates: () -> Void
    var hotkeyStatus: () -> OSStatus
    var quit: () -> Void
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: ShelfStore
    private let actions: AppActions
    private let statusItem: NSStatusItem

    init(store: ShelfStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.title = ""
        statusItem.button?.image = Self.makeMenuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "DropFlow — click for the shelf, right-click for the menu"

        // No `statusItem.menu` here: while a menu is assigned AppKit opens it on click and never sends
        // the button's action, so a plain left click could not show the shelf. The menu is attached for
        // the duration of a right-click only (see statusItemClicked).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Click handling

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            actions.toggleShelf()
            return
        }

        let menu = NSMenu()
        menu.delegate = self
        // Populate BEFORE assigning. AppKit renders the item list the menu object holds at the moment it
        // starts displaying, so anything added later shows up one open late — that is what made the first
        // click after launch produce an empty menu.
        populate(menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)  // blocks until menu tracking ends
        statusItem.menu = nil                 // restore left-click → shelf
    }

    /// Second belt: `populate` is idempotent, so re-running it here costs nothing and keeps the contents
    /// honest if AppKit ever re-opens a menu object we already built.
    func menuWillOpen(_ menu: NSMenu) {
        populate(menu)
    }

    // MARK: - Menu

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Auto-enabling re-enables any item whose target responds to its action when AppKit calls
        // update(), which silently undid the Clear Shelf / Create ZIP disabling below.
        menu.autoenablesItems = false

        menu.addItem(withTitle: "Show Shelf", action: #selector(showShelf), keyEquivalent: "")
        let toggleItem = menu.addItem(withTitle: "Toggle Shelf", action: #selector(toggleShelf), keyEquivalent: "")

        // Display only — a status-menu key equivalent is live just while the menu tracks, so it cannot
        // double-fire with the global registration. Shown only when the user has not overridden the
        // binding, so the menu never advertises a shortcut that is not the real one.
        // ponytail: the default binding is now declared here and in HotkeyController; the upgrade path is
        // one shared constant both read.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "HotkeyKeyCode") == nil, defaults.object(forKey: "HotkeyModifiers") == nil {
            toggleItem.keyEquivalent = " "
            toggleItem.keyEquivalentModifierMask = [.command, .shift]
        }

        let hotkeyStatus = actions.hotkeyStatus()
        if hotkeyStatus != noErr {
            // Without this the app just looks broken: the shortcut does nothing and nothing says why.
            let warning = menu.addItem(withTitle: "Global Shortcut Unavailable — Use This Menu", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            warning.toolTip = "Registering the global hotkey failed with error \(hotkeyStatus). Another app may own it."
        }

        menu.addItem(NSMenuItem.separator())

        let clearItem = menu.addItem(withTitle: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clearItem.isEnabled = !store.items.isEmpty

        let zipItem = menu.addItem(withTitle: "Create ZIP", action: #selector(createZip), keyEquivalent: "")
        zipItem.isEnabled = store.items.contains(where: \.isFileBacked)

        let recentItem = NSMenuItem(title: "Recent Shelves", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if store.recentSnapshots.isEmpty {
            let item = NSMenuItem(title: "No Recent Shelves", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentMenu.addItem(item)
        } else {
            for snapshot in store.recentSnapshots {
                let item = NSMenuItem(title: snapshot.title, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.representedObject = snapshot.id
                item.target = self
                recentMenu.addItem(item)
            }
        }
        menu.setSubmenu(recentMenu, for: recentItem)
        menu.addItem(recentItem)

        menu.addItem(NSMenuItem.separator())
        let launchItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = LaunchAtLoginController.isEnabled ? .on : .off

        menu.addItem(NSMenuItem.separator())
        let versionItem = menu.addItem(withTitle: "DropFlow \(UpdateController.currentVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        let autoCheckItem = menu.addItem(withTitle: "Check Automatically", action: #selector(toggleAutoCheck), keyEquivalent: "")
        autoCheckItem.state = UpdateController.isAutoCheckEnabled ? .on : .off

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit DropFlow", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.target == nil {
            item.target = self
        }
    }

    @objc private func showShelf() { actions.showShelf() }
    @objc private func toggleShelf() { actions.toggleShelf() }
    @objc private func clearShelf() { store.clearShelf() }
    @objc private func createZip() { store.zipSelectedOrAll() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func quit() { actions.quit() }

    @objc private func toggleAutoCheck() {
        UpdateController.isAutoCheckEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLoginController.toggle()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let snapshot = store.recentSnapshots.first(where: { $0.id == id })
        else { return }
        store.restore(snapshot: snapshot)
        actions.showShelf()
    }

    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            let trayRect = NSRect(x: 3.5, y: 4.5, width: 15, height: 7)
            let trayPath = NSBezierPath(roundedRect: trayRect, xRadius: 3, yRadius: 3)
            NSColor.black.setStroke()
            trayPath.lineWidth = 1.8
            trayPath.stroke()

            let lipPath = NSBezierPath()
            lipPath.move(to: NSPoint(x: 6.2, y: 11.3))
            lipPath.line(to: NSPoint(x: 15.8, y: 11.3))
            lipPath.lineWidth = 1.4
            lipPath.lineCapStyle = .round
            lipPath.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 11, y: 17.8))
            arrow.line(to: NSPoint(x: 11, y: 8.2))
            arrow.lineWidth = 2.4
            arrow.lineCapStyle = .round
            arrow.stroke()

            let arrowHead = NSBezierPath()
            arrowHead.move(to: NSPoint(x: 7.8, y: 10))
            arrowHead.line(to: NSPoint(x: 11, y: 6.6))
            arrowHead.line(to: NSPoint(x: 14.2, y: 10))
            arrowHead.lineCapStyle = .round
            arrowHead.lineJoinStyle = .round
            arrowHead.lineWidth = 2.4
            arrowHead.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
