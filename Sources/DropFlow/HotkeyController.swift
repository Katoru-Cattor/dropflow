import AppKit
import DropFlowCore
import Carbon

@MainActor
final class HotkeyController {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// `noErr` once `start()` has registered successfully. Read this to tell the user the hotkey is dead.
    /// It only catches outright registration failure: when the combo is already owned by a stock macOS
    /// shortcut the OS consumes the key upstream and `RegisterEventHotKey` still returns `noErr`.
    private(set) var lastRegistrationStatus: OSStatus = noErr

    init(action: @escaping () -> Void) {
        self.action = action
    }

    isolated deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard hotKeyID.signature == FourCharCode("DFLW") else { return noErr }
            let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.action()
            }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)
        if handlerStatus != noErr {
            NSLog("DropFlow hotkey: InstallEventHandler failed (\(handlerStatus)) — global hotkey inactive")
        }

        // Cmd-Shift-Space: every other Space combo is a stock macOS shortcut (Cmd = Spotlight,
        // Cmd-Opt = Finder search, Ctrl / Ctrl-Opt / Ctrl-Shift = input-source switching).
        // Overridable without a rebuild: `defaults write <bundle-id> HotkeyKeyCode -int <vk>` / HotkeyModifiers.
        // UInt32(exactly:), not UInt32(_:): these values are hand-typed by a user into `defaults write`,
        // and a negative or oversized one would trap here — inside applicationDidFinishLaunching, so the
        // app would crash-loop on launch with no way back except `defaults delete`.
        let keyCode = (UserDefaults.standard.object(forKey: "HotkeyKeyCode") as? Int)
            .flatMap(UInt32.init(exactly:)) ?? UInt32(kVK_Space)
        let modifiers = (UserDefaults.standard.object(forKey: "HotkeyModifiers") as? Int)
            .flatMap(UInt32.init(exactly:)) ?? UInt32(cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: FourCharCode("DFLW"), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("DropFlow hotkey: RegisterEventHotKey failed (\(registerStatus)) — global hotkey inactive")
        }
        lastRegistrationStatus = handlerStatus != noErr ? handlerStatus : registerStatus
    }
}

private func FourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + scalar.value
    }
    return result
}
