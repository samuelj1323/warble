import Foundation

/// What kind of thing happened, for recording into the current chat session.
/// Each case carries both what was said and how it was resolved, so it can be
/// split into a user turn and an assistant turn.
enum SessionEntryKind: Equatable {
    case dictation(transcript: String, pastedInto: String?)
    case macControl(transcript: String, reply: String)
    case codeChange(transcript: String, summary: String)
}

struct ChatMessage: Equatable, Identifiable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
}

/// One continuous conversation thread — like texting a single person: turns
/// keep accumulating while you speak within it. Starting a new session opens
/// a separate thread, the way switching to a different person would.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var title: String
    @Published private(set) var messages: [ChatMessage] = []

    init(id: UUID = UUID(), title: String = "New session") {
        self.id = id
        self.title = title
    }

    func append(role: ChatMessage.Role, text: String) {
        messages.append(ChatMessage(id: UUID(), role: role, text: text))
        if role == .user, title == "New session" {
            title = String(text.prefix(40))
        }
    }
}

/// Holds every conversation thread and which one is currently active. Voice
/// activity is recorded onto the current session as a user turn followed by
/// an assistant turn — the same shape as a messaging app's chat history.
@MainActor
final class SessionHistory: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID?

    var currentSession: ChatSession? {
        sessions.first { $0.id == currentSessionID }
    }

    @discardableResult
    func startNewSession() -> ChatSession {
        let session = ChatSession()
        sessions.append(session)
        currentSessionID = session.id
        return session
    }

    func record(_ kind: SessionEntryKind) {
        let session = currentSession ?? startNewSession()

        switch kind {
        case .dictation(let transcript, let pastedInto):
            session.append(role: .user, text: transcript)
            session.append(role: .assistant, text: "Pasted into \(pastedInto ?? "focused app").")
        case .macControl(let transcript, let reply):
            session.append(role: .user, text: transcript)
            session.append(role: .assistant, text: reply)
        case .codeChange(let transcript, let summary):
            session.append(role: .user, text: transcript)
            session.append(role: .assistant, text: summary)
        }
    }
}
