import AppKit

struct AppActions {
    var toggleShelf: () -> Void
    var showShelf: () -> Void
    var requestAccessibility: () -> Void
    var quit: () -> Void
}

@MainActor
final class StatusBarController: NSObject {
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
        statusItem.button?.toolTip = "DropFlow"
        rebuildMenu()

        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange), name: .shelfStoreDidChange, object: store)
    }

    @objc private func storeDidChange() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Shelf", action: #selector(showShelf), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Shelf", action: #selector(toggleShelf), keyEquivalent: "")
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
        let accessibilityItem = menu.addItem(withTitle: "Shake Activation Enabled", action: nil, keyEquivalent: "")
        accessibilityItem.isEnabled = false
        menu.addItem(withTitle: "Quit DropFlow", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.target == nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showShelf() { actions.showShelf() }
    @objc private func toggleShelf() { actions.toggleShelf() }
    @objc private func clearShelf() { store.clearShelf() }
    @objc private func createZip() { store.zipSelectedOrAll() }
    @objc private func requestAccessibility() { actions.requestAccessibility() }
    @objc private func quit() { actions.quit() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let snapshot = store.recentSnapshots.first(where: { $0.id == id })
        else { return }
        store.restore(snapshot: snapshot)
        actions.showShelf()
    }

    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high

        let trayRect = NSRect(x: 3.5, y: 4.5, width: 15, height: 7)
        let trayPath = NSBezierPath(roundedRect: trayRect, xRadius: 3, yRadius: 3)
        NSColor.black.setStroke()
        trayPath.lineWidth = 1.8
        trayPath.stroke()

        let lipPath = NSBezierPath()
        lipPath.move(to: NSPoint(x: 6.2, y: 11.3))
        lipPath.line(to: NSPoint(x: 15.8, y: 11.3))
        NSColor.black.setStroke()
        lipPath.lineWidth = 1.4
        lipPath.lineCapStyle = .round
        lipPath.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 11, y: 17.8))
        arrow.line(to: NSPoint(x: 11, y: 8.2))
        NSColor.black.setStroke()
        arrow.lineWidth = 2.4
        arrow.lineCapStyle = .round
        arrow.stroke()

        let arrowHead = NSBezierPath()
        arrowHead.move(to: NSPoint(x: 7.8, y: 10))
        arrowHead.line(to: NSPoint(x: 11, y: 6.6))
        arrowHead.line(to: NSPoint(x: 14.2, y: 10))
        arrowHead.lineCapStyle = .round
        arrowHead.lineJoinStyle = .round
        NSColor.black.setStroke()
        arrowHead.lineWidth = 2.4
        arrowHead.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
