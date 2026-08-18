import Foundation

/// A JSON scalar/collection value, used for tool_use `input` payloads whose shape
/// varies by tool (Edit/Write/MultiEdit/Bash/...).
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// A single decoded line of `claude --output-format stream-json` output. Only the
/// fields the transcript panel and diff extraction need are modeled — the real
/// CLI emits more (usage, rate_limit_event, mcp_servers, ...) which decode to `nil`.
enum ClaudeStreamEvent: Equatable {
    enum ContentItem: Equatable {
        case thinking
        case text(String)
        case toolUse(id: String, name: String, input: [String: JSONValue])
    }

    struct ToolResult: Equatable {
        let toolUseID: String?
        let content: String
    }

    case system(subtype: String)
    case assistant(content: [ContentItem])
    case user(toolResults: [ToolResult])
    case result(text: String, isError: Bool)

    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }

        switch envelope.type {
        case "system":
            self = .system(subtype: envelope.subtype ?? "")
        case "assistant":
            let items = (envelope.message?.content ?? []).compactMap(ContentItem.init(raw:))
            self = .assistant(content: items)
        case "user":
            let results = (envelope.message?.content ?? []).compactMap { raw -> ToolResult? in
                guard raw.type == "tool_result", let content = raw.content else { return nil }
                return ToolResult(toolUseID: raw.toolUseID, content: content)
            }
            self = .user(toolResults: results)
        case "result":
            self = .result(text: envelope.result ?? "", isError: envelope.isError ?? false)
        default:
            return nil
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let subtype: String?
        let message: Message?
        let result: String?
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, subtype, message, result
            case isError = "is_error"
        }
    }

    private struct Message: Decodable {
        let content: [RawContentItem]?
    }

    fileprivate struct RawContentItem: Decodable {
        let type: String
        let thinking: String?
        let text: String?
        let id: String?
        let name: String?
        let input: [String: JSONValue]?
        let toolUseID: String?
        let content: String?

        enum CodingKeys: String, CodingKey {
            case type, thinking, text, id, name, input, content
            case toolUseID = "tool_use_id"
        }
    }
}

extension ClaudeStreamEvent.ContentItem {
    fileprivate init?(raw: ClaudeStreamEvent.RawContentItem) {
        switch raw.type {
        case "thinking":
            self = .thinking
        case "text":
            guard let text = raw.text else { return nil }
            self = .text(text)
        case "tool_use":
            guard let id = raw.id, let name = raw.name else { return nil }
            self = .toolUse(id: id, name: name, input: raw.input ?? [:])
        default:
            return nil
        }
    }
}
