import XCTest
@testable import WarbleMac

final class ClaudeStreamEventTests: XCTestCase {
    // Fixtures below are real lines captured from `claude -p ... --output-format stream-json --verbose`
    // against a scratch repo, not hand-derived.

    func testDecodesSystemInitEvent() {
        let line = #"{"type":"system","subtype":"init","cwd":"/tmp/scratch-repo","session_id":"abc-123"}"#

        let event = ClaudeStreamEvent(jsonLine: line)

        XCTAssertEqual(event, .system(subtype: "init"))
    }

    func testDecodesAssistantThinkingContentItem() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"pondering"}]}}"#

        let event = ClaudeStreamEvent(jsonLine: line)

        XCTAssertEqual(event, .assistant(content: [.thinking]))
    }

    func testDecodesAssistantToolUseContentItem() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01Y4","name":"Edit","input":{"file_path":"/tmp/a.txt","old_string":"hello","new_string":"# test comment\nhello"}}]}}
        """#

        let event = ClaudeStreamEvent(jsonLine: line)

        XCTAssertEqual(event, .assistant(content: [
            .toolUse(id: "toolu_01Y4", name: "Edit", input: [
                "file_path": .string("/tmp/a.txt"),
                "old_string": .string("hello"),
                "new_string": .string("# test comment\nhello")
            ])
        ]))
    }

    func testDecodesAssistantTextContentItem() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"It looks like permission wasn't granted."}]}}"#

        let event = ClaudeStreamEvent(jsonLine: line)

        XCTAssertEqual(event, .assistant(content: [.text("It looks like permission wasn't granted.")]))
    }

    func testDecodesUserToolResultEvent() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01CbCLLZ","type":"tool_result","content":"1\thello\n2\t"}]}}"#

        let event = ClaudeStreamEvent(jsonLine: line)

        XCTAssertEqual(event, .user(toolResults: [
            ClaudeStreamEvent.ToolResult(toolUseID: "toolu_01CbCLLZ", content: "1\thello\n2\t")
        ]))
    }

    func testDecodesResultEvent() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"It looks like permission for editing that file wasn't granted.","session_id":"9b32b656"}"#

        let event = ClaudeStreamEvent(jsonLine: line)

        XCTAssertEqual(event, .result(text: "It looks like permission for editing that file wasn't granted.", isError: false))
    }

    func testReturnsNilForUnparsableLine() {
        let event = ClaudeStreamEvent(jsonLine: "not json at all")

        XCTAssertNil(event)
    }
}
