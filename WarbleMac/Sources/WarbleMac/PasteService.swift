import AppKit

/// Writes finalized dictation text to the pasteboard and simulates Cmd+V so it
/// lands in whatever app currently has focus, replacing the Electron app's
/// clipboard-write + nut-js keystroke pattern. When a specific `targetApp` is
/// given, activates it first so the paste lands there instead of wherever
/// focus already was.
@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private let sendPasteKeystroke: () -> Void
    private let frontmostAppName: () -> String?
    private let activate: (NSRunningApplication) -> Void

    init(
        pasteboard: NSPasteboard = .general,
        sendPasteKeystroke: @escaping @MainActor () -> Void = PasteService.postCmdV,
        frontmostAppName: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName },
        activate: @escaping (NSRunningApplication) -> Void = { $0.activate() }
    ) {
        self.pasteboard = pasteboard
        self.sendPasteKeystroke = sendPasteKeystroke
        self.frontmostAppName = frontmostAppName
        self.activate = activate
    }

    /// Returns the name of the app the text was pasted into (the activated
    /// `targetApp`, or whatever had focus), so callers can surface it to the
    /// user. Returns nil if there was nothing to paste.
    @discardableResult
    func paste(text: String, targetApp: NSRunningApplication? = nil) async -> String? {
        guard !text.isEmpty else { return nil }
        if let targetApp {
            activate(targetApp)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendPasteKeystroke()
        return targetApp?.localizedName ?? frontmostAppName()
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
