import Foundation

/// Where a session's typed/sent text is pasted. Persisted per session, so it
/// must survive a relaunch — hence a stable bundle identifier rather than a
/// live `NSRunningApplication` process handle (which is only valid for one run).
enum PasteTarget: Codable, Equatable, Hashable {
    /// Paste into whatever app currently has focus (the historical default).
    case focusedApp
    /// Paste into a specific app, launching/activating it if needed. `name` is
    /// kept alongside the id purely so the UI can label it without resolving the
    /// bundle when the app isn't running.
    case app(bundleID: String, name: String)
}

/// Per-session configuration: what repo code-changes target, whether utterances
/// are routed through the agent classifier, where sent text is pasted, and the
/// resumable Claude Code conversation id. Lives on `ChatSession` (not globally
/// on `AppModel`) so each thread is independently scoped to a repo + destination
/// + mode, and is `Codable` so the whole thing persists across launches.
struct SessionConfig: Codable, Equatable {
    /// Absolute path to the repo code-change intents run against. Empty means the
    /// session has no repo, so code-change requests are declined.
    var repoRoot: String = ""
    /// When true, finalized utterances are classified (mac-control / code-change
    /// / chat) and routed; when false, everything is raw dictation.
    var agentModeEnabled: Bool = false
    /// Where an explicit Send pastes the composed text.
    var pasteTarget: PasteTarget = .focusedApp
    /// The claude `session_id` captured from this thread's first code-change turn,
    /// persisted so a follow-up after relaunch resumes the same conversation.
    var claudeSessionID: String?
}
