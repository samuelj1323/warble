import XCTest
@testable import WarbleMac

@MainActor
final class ClaudeCodeSessionTests: XCTestCase {
    private func stream(of lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }

    func testRunAccumulatesEventsAndPendingEditsFromStreamedLines() async {
        let editLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Edit","input":{"file_path":"/tmp/a.txt","old_string":"hi","new_string":"hey"}}]}}"#
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _ in
            self.stream(of: [editLine])
        })

        await session.run(prompt: "rename the greeting")

        XCTAssertEqual(session.events, [
            .assistant(content: [.toolUse(id: "1", name: "Edit", input: [
                "file_path": .string("/tmp/a.txt"),
                "old_string": .string("hi"),
                "new_string": .string("hey")
            ])])
        ])
        XCTAssertEqual(session.pendingEdits, [
            PendingEdit(filePath: "/tmp/a.txt", oldText: "hi", newText: "hey")
        ])
    }

    func testRunCapturesFinalResultTextAndClearsIsRunning() async {
        let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"done editing"}"#
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _ in
            self.stream(of: [resultLine])
        })

        await session.run(prompt: "do the thing")

        XCTAssertEqual(session.finalResultText, "done editing")
        XCTAssertFalse(session.isRunning)
    }

    func testRunIgnoresUnparsableLinesWithoutCrashing() async {
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _ in
            self.stream(of: ["garbage", "more garbage"])
        })

        await session.run(prompt: "do the thing")

        XCTAssertEqual(session.events, [])
    }
}
