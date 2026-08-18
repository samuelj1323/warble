import AppKit

/// Menu-bar icon reflecting dictation status, replacing Electron's `Tray`.
/// Not unit-testable (owns a real NSStatusItem); the idle/recording/transcribing
/// glyph mapping itself is covered by TrayIconStateTests.
@MainActor
final class TrayIconController {
    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        update(status: .idle)
    }

    func update(status: DictationStatus) {
        statusItem.button?.title = TrayIconState.glyph(for: status)
        statusItem.button?.toolTip = "Warble — \(status)"
    }
}

extension DictationStatus: CustomStringConvertible {
    var description: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        }
    }
}
