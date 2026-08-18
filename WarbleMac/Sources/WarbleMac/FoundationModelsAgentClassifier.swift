import FoundationModels

/// Classifies a finalized agent-mode utterance using Apple's on-device
/// Foundation Models framework — no network call, replacing `server/agent.py`'s
/// OpenRouter round-trip. Not unit-tested (needs a real on-device model);
/// AgentRouterTests cover dispatch against an injected classifier instead.
@available(macOS 26.0, *)
enum FoundationModelsAgentClassifier {
    @Generable
    struct Classification {
        @Guide(description: "The kind of request this utterance represents")
        var kind: Kind

        @Guide(description: "For mac_control: which tool to call")
        var tool: String?

        @Guide(description: "For mac_control open_app: the application name")
        var appName: String?

        @Guide(description: "For mac_control open_url: the URL")
        var url: String?

        @Guide(description: "For mac_control set_volume: the volume level 0-100")
        var volumeLevel: Int?

        @Guide(description: "For mac_control set_mute: true to mute, false to unmute")
        var muted: Bool?

        @Guide(description: "For mac_control media_control: play_pause, next, or previous")
        var mediaAction: String?

        @Guide(description: "For chat: the reply text to speak back")
        var chatReply: String?

        @Generable
        enum Kind: String {
            case macControl = "mac_control"
            case codeChange = "code_change"
            case chat
        }
    }

    private static let instructions = """
    You classify a voice transcript spoken to a Mac-control assistant into one \
    of three kinds: mac_control (the user wants an app opened, a URL opened, \
    volume/mute changed, the screen locked or slept, a screenshot taken, or \
    media playback controlled), code_change (the user wants source code \
    modified), or chat (anything else — reply briefly in chatReply).
    """

    static func classify(_ transcript: String) async -> AgentIntent {
        let session = LanguageModelSession(instructions: instructions)
        guard let response = try? await session.respond(to: transcript, generating: Classification.self) else {
            return .chat(reply: "Sorry, I couldn't understand that.")
        }

        let classification = response.content
        switch classification.kind {
        case .macControl:
            return .macControl(tool: classification.tool ?? "", arguments: arguments(from: classification))
        case .codeChange:
            return .codeChange
        case .chat:
            return .chat(reply: classification.chatReply ?? "")
        }
    }

    private static func arguments(from classification: Classification) -> [String: String] {
        var arguments: [String: String] = [:]
        if let appName = classification.appName { arguments["name"] = appName }
        if let url = classification.url { arguments["url"] = url }
        if let volumeLevel = classification.volumeLevel { arguments["level"] = String(volumeLevel) }
        if let muted = classification.muted { arguments["muted"] = muted ? "true" : "false" }
        if let mediaAction = classification.mediaAction { arguments["action"] = mediaAction }
        return arguments
    }
}
