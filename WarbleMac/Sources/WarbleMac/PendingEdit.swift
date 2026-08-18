import Foundation

/// A proposed file change from a Claude Code session's tool_use events, rendered
/// in the diff panel. Only written to disk via `applyPendingEdits`, a deliberate
/// UI-only action — Claude Code's own permission gate is never approved.
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

enum ApplyPendingEditError: Error, Equatable {
    case oldTextNotFound(filePath: String)
}

/// Writes reviewed pending edits to disk. The only place a code-change session
/// ever writes files — invoked exclusively by a UI Apply action, never by
/// voice/router dispatch.
@discardableResult
func applyPendingEdits(_ edits: [PendingEdit]) throws -> [String] {
    var writtenPaths: [String] = []
    for edit in edits {
        if edit.oldText.isEmpty {
            try edit.newText.write(toFile: edit.filePath, atomically: true, encoding: .utf8)
        } else {
            let existing = try String(contentsOfFile: edit.filePath, encoding: .utf8)
            guard existing.contains(edit.oldText) else {
                throw ApplyPendingEditError.oldTextNotFound(filePath: edit.filePath)
            }
            let updated = existing.replacingOccurrences(of: edit.oldText, with: edit.newText)
            try updated.write(toFile: edit.filePath, atomically: true, encoding: .utf8)
        }
        writtenPaths.append(edit.filePath)
    }
    return writtenPaths
}
