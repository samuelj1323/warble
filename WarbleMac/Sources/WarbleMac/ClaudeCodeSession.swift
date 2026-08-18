import Foundation

/// Accumulates raw process output and splits it into newline-delimited lines.
/// `readabilityHandler` runs on a background queue, so this is a plain class
/// with unchecked Sendable rather than an actor — avoids an async hop per chunk.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func appendAndExtractLines(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        var lines: [String] = []
        while let newlineRange = data.range(of: Data([0x0A])) {
            let lineData = data.subdata(in: data.startIndex..<newlineRange.lowerBound)
            data.removeSubrange(data.startIndex..<newlineRange.upperBound)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}

/// Drives a `claude --output-format stream-json` subprocess for a code-change
/// request, accumulating the transcript and the diff it proposes. View-only:
/// Claude Code's own permission gate is left unapproved, so Edit/Write tool_use
/// events stream their intended old/new content but are never actually applied
/// to disk — see PendingEdit.
@MainActor
final class ClaudeCodeSession: ObservableObject {
    typealias LineSource = (_ prompt: String, _ repoRoot: String) -> AsyncThrowingStream<String, Error>

    @Published private(set) var events: [ClaudeStreamEvent] = []
    @Published private(set) var pendingEdits: [PendingEdit] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var finalResultText: String?

    private let repoRoot: String
    private let lineSource: LineSource

    init(repoRoot: String, lineSource: LineSource? = nil) {
        self.repoRoot = repoRoot
        self.lineSource = lineSource ?? Self.realLineSource
    }

    func run(prompt: String) async {
        isRunning = true
        events = []
        pendingEdits = []
        finalResultText = nil

        do {
            for try await line in lineSource(prompt, repoRoot) {
                guard let event = ClaudeStreamEvent(jsonLine: line) else { continue }
                events.append(event)
                pendingEdits = extractPendingEdits(from: events)
                if case .result(let text, _) = event {
                    finalResultText = text
                }
            }
        } catch {
            // Streaming failures leave whatever transcript/diff was captured so far
            // visible rather than discarding it.
        }

        isRunning = false
    }

    nonisolated private static func realLineSource(prompt: String, repoRoot: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose"]
            process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            process.terminationHandler = { _ in
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let handle = stdoutPipe.fileHandleForReading
            let buffer = LineBuffer()
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                for line in buffer.appendAndExtractLines(data) {
                    continuation.yield(line)
                }
            }

            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
