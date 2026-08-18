import XCTest
@testable import WarbleMac

final class PendingEditExtractionTests: XCTestCase {
    func testExtractsPendingEditFromEditToolUse() {
        let events: [ClaudeStreamEvent] = [
            .assistant(content: [
                .toolUse(id: "1", name: "Edit", input: [
                    "file_path": .string("/tmp/a.txt"),
                    "old_string": .string("hello"),
                    "new_string": .string("# comment\nhello")
                ])
            ])
        ]

        let edits = extractPendingEdits(from: events)

        XCTAssertEqual(edits, [
            PendingEdit(filePath: "/tmp/a.txt", oldText: "hello", newText: "# comment\nhello")
        ])
    }

    func testExtractsPendingEditFromWriteToolUseWithEmptyOldText() {
        let events: [ClaudeStreamEvent] = [
            .assistant(content: [
                .toolUse(id: "2", name: "Write", input: [
                    "file_path": .string("/tmp/new.txt"),
                    "content": .string("brand new file\n")
                ])
            ])
        ]

        let edits = extractPendingEdits(from: events)

        XCTAssertEqual(edits, [
            PendingEdit(filePath: "/tmp/new.txt", oldText: "", newText: "brand new file\n")
        ])
    }

    func testIgnoresNonEditToolUseAndOtherContentItems() {
        let events: [ClaudeStreamEvent] = [
            .assistant(content: [
                .thinking,
                .text("looking at the file"),
                .toolUse(id: "3", name: "Read", input: ["file_path": .string("/tmp/a.txt")])
            ]),
            .user(toolResults: [ClaudeStreamEvent.ToolResult(toolUseID: "3", content: "hello")]),
            .result(text: "done", isError: false)
        ]

        let edits = extractPendingEdits(from: events)

        XCTAssertEqual(edits, [])
    }
}
