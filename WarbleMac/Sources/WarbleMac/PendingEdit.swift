/// A proposed file change from a Claude Code session's tool_use events, rendered
/// in the diff panel. Never written to disk by this app — Claude Code's own
/// permission gate (left unapproved) already guarantees that.
struct PendingEdit: Equatable {
    let filePath: String
    let oldText: String
    let newText: String
}

/// Scans a Claude Code stream-json transcript for Edit/Write tool_use calls and
/// extracts the diff they propose.
func extractPendingEdits(from events: [ClaudeStreamEvent]) -> [PendingEdit] {
    events.flatMap { event -> [PendingEdit] in
        guard case .assistant(let content) = event else { return [] }
        return content.compactMap { item -> PendingEdit? in
            guard case .toolUse(_, let name, let input) = item else { return nil }
            guard let filePath = input["file_path"]?.stringValue else { return nil }

            switch name {
            case "Edit":
                guard let oldText = input["old_string"]?.stringValue,
                      let newText = input["new_string"]?.stringValue else { return nil }
                return PendingEdit(filePath: filePath, oldText: oldText, newText: newText)
            case "Write":
                guard let newText = input["content"]?.stringValue else { return nil }
                return PendingEdit(filePath: filePath, oldText: "", newText: newText)
            default:
                return nil
            }
        }
    }
}
