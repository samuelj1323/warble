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
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _, _ in
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
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _, _ in
            self.stream(of: [resultLine])
        })

        await session.run(prompt: "do the thing")

        XCTAssertEqual(session.finalResultText, "done editing")
        XCTAssertFalse(session.isRunning)
    }

    func testRunIgnoresUnparsableLinesWithoutCrashing() async {
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _, _ in
            self.stream(of: ["garbage", "more garbage"])
        })

        await session.run(prompt: "do the thing")

        XCTAssertEqual(session.events, [])
    }

    func testFollowUpRunAccumulatesPendingEditsInsteadOfResetting() async {
        let firstEditLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Edit","input":{"file_path":"/tmp/a.txt","old_string":"hi","new_string":"hey"}}]}}"#
        let secondEditLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"2","name":"Edit","input":{"file_path":"/tmp/b.txt","old_string":"bye","new_string":"later"}}]}}"#
        var callCount = 0
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _, _ in
            callCount += 1
            return self.stream(of: [callCount == 1 ? firstEditLine : secondEditLine])
        })

        await session.run(prompt: "rename the greeting")
        await session.run(prompt: "also rename the farewell")

        XCTAssertEqual(session.pendingEdits, [
            PendingEdit(filePath: "/tmp/a.txt", oldText: "hi", newText: "hey"),
            PendingEdit(filePath: "/tmp/b.txt", oldText: "bye", newText: "later")
        ])
    }

    func testFollowUpRunPassesSessionIDCapturedFromFirstRunToLineSource() async {
        let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp/scratch","session_id":"abc-123"}"#
        var capturedResumeIDs: [String?] = []
        let session = ClaudeCodeSession(repoRoot: "/tmp/scratch", lineSource: { _, _, resumeSessionID in
            capturedResumeIDs.append(resumeSessionID)
            return self.stream(of: [initLine])
        })

        await session.run(prompt: "first turn")
        await session.run(prompt: "second turn")

        XCTAssertEqual(capturedResumeIDs, [nil, "abc-123"])
    }

    func testApplyWritesPendingEditsToDiskAndClearsThem() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("a.txt")
        try "hi".write(to: filePath, atomically: true, encoding: .utf8)

        let editLine = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Edit","input":{"file_path":"\#(filePath.path)","old_string":"hi","new_string":"hey"}}]}}
        """#
        let session = ClaudeCodeSession(repoRoot: tempDir.path, lineSource: { _, _, _ in
            self.stream(of: [editLine])
        })
        await session.run(prompt: "rename the greeting")

        try session.apply()

        XCTAssertEqual(session.pendingEdits, [])
        let contents = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(contents, "hey")
    }

    func testDiscardClearsPendingEditsWithoutWritingToDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("a.txt")
        try "hi".write(to: filePath, atomically: true, encoding: .utf8)

        let editLine = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Edit","input":{"file_path":"\#(filePath.path)","old_string":"hi","new_string":"hey"}}]}}
        """#
        let session = ClaudeCodeSession(repoRoot: tempDir.path, lineSource: { _, _, _ in
            self.stream(of: [editLine])
        })
        await session.run(prompt: "rename the greeting")

        session.discard()

        XCTAssertEqual(session.pendingEdits, [])
        let contents = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(contents, "hi")
    }
}
