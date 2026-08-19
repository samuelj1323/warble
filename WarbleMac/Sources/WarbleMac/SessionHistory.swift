import Foundation

/// What kind of thing happened, for recording into the current chat session.
/// Each case carries both what was said and how it was resolved, so it can be
/// split into a user turn and an assistant turn.
enum SessionEntryKind: Equatable {
    case dictation(transcript: String, pastedInto: String?)
    case macControl(transcript: String, reply: String)
    case codeChange(transcript: String, summary: String)
}

struct ChatMessage: Equatable, Identifiable, Codable {
    enum Role: Equatable, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
}

/// Flat, Codable snapshot of a session for persistence — the live `ChatSession`
/// is a `@MainActor` `ObservableObject`, so it's mapped to/from this plain value
/// rather than made Codable itself.
struct PersistedSession: Codable {
    let id: UUID
    let title: String
    let messages: [ChatMessage]
    let config: SessionConfig
}

/// The whole persisted state: every thread plus which one was active.
struct PersistedState: Codable {
    var sessions: [PersistedSession]
    var currentSessionID: UUID?
}

/// One continuous conversation thread — like texting a single person: turns
/// keep accumulating while you speak within it. Starting a new session opens
/// a separate thread, the way switching to a different person would. Each
/// session is independently scoped by its `config` (repo, paste target, agent
/// mode) and owns its own code-change conversation.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var title: String
    @Published private(set) var messages: [ChatMessage] = []
    /// True between sending an utterance and the assistant's reply landing, so
    /// the transcript can show a "thinking…" bubble while the model works.
    /// Transient (not persisted) — a reply is never in flight across a relaunch.
    @Published var isAwaitingReply: Bool = false
    /// Per-session repo / paste-target / agent-mode / resumable-claude-id.
    /// Editable live from the session-config header.
    @Published var config: SessionConfig {
        didSet { didMutate?() }
    }

    /// Called after any persistable mutation (message appended, title/config
    /// changed) so `SessionHistory` can save. Set by the owning history.
    var didMutate: (() -> Void)?

    private var _codeSession: ClaudeCodeSession?
    private var _codeSessionRepo: String?

    init(
        id: UUID = UUID(),
        title: String = "New session",
        messages: [ChatMessage] = [],
        config: SessionConfig = SessionConfig()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.config = config
    }

    /// This thread's own code-change session, scoped to its repo. Rebuilt when
    /// the repo changes (a persisted claude id belongs to the previous repo's
    /// conversation, so it's only used to rehydrate the session on first access
    /// after load — not carried across a repo switch). Nil when no repo is set.
    var codeSession: ClaudeCodeSession? {
        let repo = config.repoRoot
        guard !repo.isEmpty else { return nil }
        if let existing = _codeSession, _codeSessionRepo == repo { return existing }
        let resume = (_codeSessionRepo == nil) ? config.claudeSessionID : nil
        let session = ClaudeCodeSession(repoRoot: repo, resumeSessionID: resume)
        _codeSession = session
        _codeSessionRepo = repo
        return session
    }

    func append(role: ChatMessage.Role, text: String) {
        messages.append(ChatMessage(id: UUID(), role: role, text: text))
        if role == .user, title == "New session" {
            title = String(text.prefix(40))
        }
        didMutate?()
    }

    var persisted: PersistedSession {
        PersistedSession(id: id, title: title, messages: messages, config: config)
    }
}

/// Holds every conversation thread and which one is currently active, persisting
/// the lot to disk. Voice activity is recorded onto the current session as a
/// user turn followed by an assistant turn — the same shape as a messaging app's
/// chat history.
@MainActor
final class SessionHistory: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID? {
        didSet { persist() }
    }

    private let store: SessionStore

    init(store: SessionStore = SessionStore()) {
        self.store = store
        load()
    }

    var currentSession: ChatSession? {
        sessions.first { $0.id == currentSessionID }
    }

    @discardableResult
    func startNewSession() -> ChatSession {
        // New sessions start blank (no repo, focused-app paste, agent off) — the
        // config header configures them per thread.
        let session = ChatSession()
        wire(session)
        sessions.append(session)
        currentSessionID = session.id
        persist()
        return session
    }

    func record(_ kind: SessionEntryKind) {
        switch kind {
        case .dictation(let transcript, let pastedInto):
            appendUserMessage(transcript)
            appendAssistantMessage("Pasted into \(pastedInto ?? "focused app").")
        case .macControl(let transcript, let reply):
            appendUserMessage(transcript)
            appendAssistantMessage(reply)
        case .codeChange(let transcript, let summary):
            appendUserMessage(transcript)
            appendAssistantMessage(summary)
        }
    }

    /// Appends your turn immediately on send (before any await), so a typed or
    /// reviewed-dictation message shows in the transcript while the reply is
    /// still pending — the same as seeing your text appear the instant you hit
    /// send in a messaging app.
    func appendUserMessage(_ text: String) {
        let session = currentSession ?? startNewSession()
        session.append(role: .user, text: text)
    }

    /// Appends the assistant's turn once the reply (or paste confirmation) is
    /// known, and clears the pending "thinking…" state.
    func appendAssistantMessage(_ text: String) {
        let session = currentSession ?? startNewSession()
        session.append(role: .assistant, text: text)
        session.isAwaitingReply = false
    }

    func setAwaitingReply(_ awaiting: Bool) {
        currentSession?.isAwaitingReply = awaiting
    }

    /// Routes a live session's mutations back into a save. Called for every
    /// session as it's created or loaded.
    private func wire(_ session: ChatSession) {
        session.didMutate = { [weak self] in self?.persist() }
    }

    private func load() {
        guard let state = store.load(PersistedState.self) else { return }
        sessions = state.sessions.map { persisted in
            ChatSession(id: persisted.id, title: persisted.title, messages: persisted.messages, config: persisted.config)
        }
        sessions.forEach(wire)
        currentSessionID = state.currentSessionID ?? sessions.first?.id
    }

    private func persist() {
        let state = PersistedState(
            sessions: sessions.map(\.persisted),
            currentSessionID: currentSessionID
        )
        store.save(state)
    }
}
