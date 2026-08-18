import Foundation

/// Intent classification for a finalized agent-mode utterance.
enum AgentIntent {
    case macControl(tool: String, arguments: [String: String])
    case codeChange
    case chat(reply: String)
}

/// Classifies a transcript and dispatches it, replacing `server/agent.py`'s
/// OpenRouter round-trip with on-device classification (no network call).
/// The `classify` closure defaults to nothing usable in tests — production
/// wiring supplies the real Foundation Models-backed classifier.
final class AgentRouter: @unchecked Sendable {
    typealias Classifier = (String) async -> AgentIntent

    private let tools: MacControlTools
    private let tts: TTSService
    private let classify: Classifier
    private let runCodeChange: ((String) async -> String)?
    private let onDispatch: ((AgentIntent, String) -> Void)?

    init(
        tools: MacControlTools,
        tts: TTSService,
        classify: @escaping Classifier,
        runCodeChange: ((String) async -> String)? = nil,
        onDispatch: ((AgentIntent, String) -> Void)? = nil
    ) {
        self.tools = tools
        self.tts = tts
        self.classify = classify
        self.runCodeChange = runCodeChange
        self.onDispatch = onDispatch
    }

    @discardableResult
    func handle(transcript: String) async -> String {
        let intent = await classify(transcript)
        let reply: String

        switch intent {
        case .macControl(let tool, let arguments):
            reply = dispatch(tool: tool, arguments: arguments)
        case .codeChange:
            if let runCodeChange {
                reply = await runCodeChange(transcript)
            } else {
                reply = "Code-change requests aren't handled yet."
            }
        case .chat(let text):
            reply = text
        }

        tts.speak(reply)
        onDispatch?(intent, reply)
        return reply
    }

    private func dispatch(tool: String, arguments: [String: String]) -> String {
        switch tool {
        case "open_app":
            return tools.openApp(name: arguments["name"] ?? "")
        case "open_url":
            return tools.openURL(arguments["url"] ?? "")
        case "set_volume":
            return tools.setVolume(level: Int(arguments["level"] ?? "") ?? 0)
        case "set_mute":
            return tools.setMute(muted: arguments["muted"] == "true")
        case "lock_screen":
            return tools.lockScreen()
        case "sleep_display":
            return tools.sleepDisplay()
        case "take_screenshot":
            return tools.takeScreenshot()
        case "media_control":
            return tools.mediaControl(action: arguments["action"] ?? "")
        default:
            return "unknown tool: \(tool)"
        }
    }
}
