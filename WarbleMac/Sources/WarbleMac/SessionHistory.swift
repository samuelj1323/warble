import Foundation

/// What kind of thing happened in a session, for the sidebar history list.
enum SessionEntryKind: Equatable {
    case dictation(transcript: String)
    case macControl(reply: String)
    case codeChange
}

struct SessionEntry: Equatable, Identifiable {
    let id: UUID
    let kind: SessionEntryKind
}

/// Records dictation utterances, mac-control actions, and code-change sessions
/// as they happen, in order, for the sidebar's session/history list.
@MainActor
final class SessionHistory: ObservableObject {
    @Published private(set) var entries: [SessionEntry] = []

    func record(_ kind: SessionEntryKind) {
        entries.append(SessionEntry(id: UUID(), kind: kind))
    }
}
