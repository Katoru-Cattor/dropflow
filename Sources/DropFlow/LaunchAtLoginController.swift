import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            return true
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error)")
            return false
        }
    }

    static func toggle() {
        setEnabled(!isEnabled)
    }
}
