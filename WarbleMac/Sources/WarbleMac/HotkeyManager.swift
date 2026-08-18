import Carbon.HIToolbox
import Foundation

/// Registers a global ⌘⇧D hotkey via Carbon's RegisterEventHotKey, replacing
/// Electron's `globalShortcut.register`. Works regardless of which app has
/// focus. Not unit-testable (OS-level global event tap); verified manually.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void

    private static let signature: OSType = 0x5741_524C // 'WARL'
    private static let hotKeyID = UInt32(1)

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    func register() {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onPress()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let cmdShift = UInt32(cmdKey | shiftKey)
        let keyCodeD = UInt32(kVK_ANSI_D)
        RegisterEventHotKey(keyCodeD, cmdShift, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
