import AppKit

/// Writes finalized dictation text to the pasteboard and simulates Cmd+V so it
/// lands in whatever app currently has focus, replacing the Electron app's
/// clipboard-write + nut-js keystroke pattern.
final class PasteService {
    private let pasteboard: NSPasteboard
    private let sendPasteKeystroke: () -> Void

    init(pasteboard: NSPasteboard = .general, sendPasteKeystroke: @escaping () -> Void = PasteService.postCmdV) {
        self.pasteboard = pasteboard
        self.sendPasteKeystroke = sendPasteKeystroke
    }

    func paste(text: String) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendPasteKeystroke()
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
