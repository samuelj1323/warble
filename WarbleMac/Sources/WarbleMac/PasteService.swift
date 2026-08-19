import AppKit

/// Writes finalized dictation text to the pasteboard and simulates Cmd+V so it
/// lands in whatever app currently has focus, replacing the Electron app's
/// clipboard-write + nut-js keystroke pattern. When the session's `PasteTarget`
/// names a specific app, resolves it by bundle id — launching/activating it if
/// it isn't already running — so text reliably lands there instead of wherever
/// focus happened to be.
@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private let sendPasteKeystroke: () -> Void
    private let frontmostAppName: () -> String?
    private let activate: (NSRunningApplication) -> Void
    private let reactivateSelf: () -> Void
    private let runningApp: (String) -> NSRunningApplication?
    private let launchApp: (String) async -> NSRunningApplication?

    init(
        pasteboard: NSPasteboard = .general,
        sendPasteKeystroke: @escaping @MainActor () -> Void = PasteService.postCmdV,
        frontmostAppName: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName },
        activate: @escaping (NSRunningApplication) -> Void = { $0.activate() },
        reactivateSelf: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        runningApp: @escaping (String) -> NSRunningApplication? = PasteService.runningApp(withBundleID:),
        launchApp: @escaping @MainActor (String) async -> NSRunningApplication? = PasteService.launchApp(withBundleID:)
    ) {
        self.pasteboard = pasteboard
        self.sendPasteKeystroke = sendPasteKeystroke
        self.frontmostAppName = frontmostAppName
        self.activate = activate
        self.reactivateSelf = reactivateSelf
        self.runningApp = runningApp
        self.launchApp = launchApp
    }

    /// Returns the name of the app the text was pasted into (the resolved target,
    /// or whatever had focus), so callers can surface it to the user. Returns nil
    /// if there was nothing to paste.
    @discardableResult
    func paste(text: String, target: PasteTarget = .focusedApp) async -> String? {
        guard !text.isEmpty else { return nil }

        var targetName: String?
        var didActivateOther = false
        if case .app(let bundleID, let name) = target {
            // Prefer an already-running instance; otherwise launch it. Only claim
            // the target name once we actually have an app to activate, so a
            // failed launch reports the real (focused) destination instead.
            var resolved = runningApp(bundleID)
            if resolved == nil { resolved = await launchApp(bundleID) }
            if let app = resolved {
                activate(app)
                didActivateOther = true
                targetName = name
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendPasteKeystroke()

        // Pasting into a target app steals the frontmost/key status from Warble.
        // Without pulling it back, the composer text field stops receiving
        // keystrokes and the user's next typing lands in the app just pasted
        // into. Give the Cmd+V a beat to be delivered to the target, then
        // reactivate Warble so the composer stays editable.
        if didActivateOther {
            try? await Task.sleep(nanoseconds: 120_000_000)
            reactivateSelf()
        }
        return targetName ?? frontmostAppName()
    }

    nonisolated private static func runningApp(withBundleID bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func launchApp(withBundleID bundleID: String) async -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
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
