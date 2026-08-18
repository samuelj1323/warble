/// Dictation lifecycle states shown by the menu-bar tray icon, replacing the
/// Electron tray's idle/listening/error glyph states.
enum DictationStatus {
    case idle
    case recording
    case transcribing
}

enum TrayIconState {
    static func glyph(for status: DictationStatus) -> String {
        switch status {
        case .idle: return "🎙️"
        case .recording: return "🔴"
        case .transcribing: return "⏳"
        }
    }
}
