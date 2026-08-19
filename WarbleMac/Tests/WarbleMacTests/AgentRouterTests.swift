import XCTest
@testable import WarbleMac

@MainActor
final class AgentRouterTests: XCTestCase {
    func testMacControlIntentDispatchesToolAndSpeaksResult() async {
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { _, arguments in
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })
        let router = AgentRouter(
            tools: tools,
            classify: { _ in .macControl(tool: "open_app", arguments: ["name": "Safari"]) }
        )

        let reply = await router.handle(transcript: "open Safari")

        XCTAssertEqual(capturedArguments, ["-a", "Safari"])
        XCTAssertEqual(reply, "opened Safari")
    }

    func testCodeChangeIntentReturnsStubWithoutTouchingTools() async {
        let tools = MacControlTools(runProcess: { _, _ in
            XCTFail("code-change intent should not dispatch a Mac-control tool")
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })
        let router = AgentRouter(tools: tools, classify: { _ in .codeChange })

        let reply = await router.handle(transcript: "add a comment to main.py")

        XCTAssertEqual(reply, "Code-change requests aren't handled yet.")
    }

    func testChatIntentSpeaksAndReturnsTheClassifiedReplyText() async {
        let tools = MacControlTools(runProcess: { _, _ in
            MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })
        let router = AgentRouter(tools: tools, classify: { _ in .chat(reply: "Hello there") })

        let reply = await router.handle(transcript: "hi")

        XCTAssertEqual(reply, "Hello there")
    }
}
