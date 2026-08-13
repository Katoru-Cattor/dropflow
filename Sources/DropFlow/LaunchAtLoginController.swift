import AppKit
import DropFlowCore
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
    /// `.requiresApproval` means the login item IS registered and only waiting for the user to flip it on
    /// in System Settings. Reporting that as off left the menu item looking dead and invited a second
    /// click, which unregistered what the first click had just registered.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
                if service.status == .requiresApproval {
                    // Registration succeeded but macOS parked the item behind a user approval. Nothing
                    // else would tell the user why DropFlow still does not launch at login.
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return true
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = enabled
                ? "Could not add DropFlow to Login Items"
                : "Could not remove DropFlow from Login Items"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Login Items")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
            return false
        }
    }

    @discardableResult
    static func toggle() -> Bool {
        setEnabled(!isEnabled)
    }
}
