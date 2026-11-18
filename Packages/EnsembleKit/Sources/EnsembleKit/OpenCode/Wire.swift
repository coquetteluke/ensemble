import Foundation

/// Wire formats of the OpenCode 2.3 HTTP API (see docs/reference/opencode-2.3.0-openapi.json).
/// Only the fields Ensemble uses are decoded; unknown fields are ignored so newer engines still decode.
/// Times are milliseconds since 1970. Most responses are wrapped as `{"data": ...}`.
enum Wire {
    struct DataEnvelope<T: Decodable>: Decodable {
        let data: T
    }

    struct Cursor: Decodable {
        let previous: String?
        let next: String?
    }

    struct Page<T: Decodable>: Decodable {
        let data: [T]
        let cursor: Cursor?
    }

    /// Decodes `T` or nothing, so one odd item does not fail a whole list.
    struct Lossy<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    /// Location-scoped responses: `{"location": {...}, "data": ...}`.
    struct LocationEnvelope<T: Decodable>: Decodable {
        let location: LocationRef?
        let data: T
    }

    struct LocationRef: Codable, Hashable {
        let directory: String
    }

    struct ModelRef: Codable, Hashable {
        let id: String
        let providerID: String
        let variant: String?
    }

    struct Tokens: Codable, Hashable {
        struct Cache: Codable, Hashable {
            let read: Double
            let write: Double
        }

        let input: Double
        let output: Double
        let reasoning: Double
        let cache: Cache
    }

    struct Rule: Codable, Hashable {
        let action: String
        let resource: String
        let effect: String
    }

    struct StructuredError: Decodable, Hashable {
        let type: String
        let message: String
        let status: Int?
    }

    // MARK: Server

    struct ServerInfo: Decodable {
        let version: String
        let pid: Int?
        let hostname: String?
        let urls: [String]?
    }

    // MARK: Sessions

    struct SessionTime: Decodable, Hashable {
        let created: Double
        let updated: Double
        let busy: Double?
        let idle: Double?
        let viewed: Double?
        let archived: Double?
    }

    struct Session: Decodable, Hashable {
        let id: String
        let parentID: String?
        let projectID: String?
        let agent: String?
        let model: ModelRef?
        let cost: Double?
        let tokens: Tokens?
        let outcome: String?
        let time: SessionTime
        let title: String?
        let location: LocationRef?
        let metadata: JSONValue?
        let permissions: [Rule]?
    }

    // MARK: Messages

    struct MessageTime: Decodable, Hashable {
        let created: Double
        let firstToken: Double?
        let streamed: Double?
        let completed: Double?
    }

    struct FileAttachment: Decodable, Hashable {
        struct Source: Decodable, Hashable {
            let type: String
            let uri: String?
        }

        let mime: String?
        let name: String?
        let source: Source?
    }

    struct ToolContent: Decodable, Hashable {
        let type: String
        let text: String?
        let uri: String?
        let mime: String?
        let name: String?
    }

    struct ToolState: Decodable, Hashable {
        let status: String
        let input: JSONValue?
        let content: [ToolContent]?
        let metadata: JSONValue?
        let error: StructuredError?
    }

    struct PartTime: Decodable, Hashable {
        let created: Double?
        let ran: Double?
        let completed: Double?
    }

    enum AssistantPart: Decodable, Hashable {
        case text(String)
        case reasoning(text: String, completed: Bool)
        case tool(Tool)
        case unknown(String)

        struct Tool: Decodable, Hashable {
            let id: String
            let name: String
            let state: ToolState
            let time: PartTime?
        }

        private enum CodingKeys: String, CodingKey { case type, text, time }
        private struct ReasoningTime: Decodable { let completed: Double? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
            case "reasoning":
                let time = try container.decodeIfPresent(ReasoningTime.self, forKey: .time)
                self = .reasoning(text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                                  completed: time?.completed != nil)
            case "tool":
                self = .tool(try Tool(from: decoder))
            default:
                self = .unknown(type)
            }
        }
    }

    struct ShellOutput: Decodable, Hashable {
        let output: String
        let truncated: Bool?
    }

    /// One entry of `GET /api/session/{id}/message` (and `/context`).
    struct Message: Decodable, Hashable {
        let id: String
        let type: String
        let time: MessageTime
        let metadata: JSONValue?
        // user, synthetic, system, skill
        let text: String?
        let description: String?
        let files: [FileAttachment]?
        // assistant
        let agent: String?
        let model: ModelRef?
        let content: [AssistantPart]?
        let finish: String?
        let cost: Double?
        let tokens: Tokens?
        let error: StructuredError?
        // skill
        let name: String?
        // shell
        let shellID: String?
        let command: String?
        let status: String?
        let output: ShellOutput?
        // compaction
        let reason: String?
        let summary: String?
        // idle
        let outcome: String?
        // switches
        let previous: JSONValue?
        let location: LocationRef?
    }

    // MARK: Permissions

    struct PermissionRequest: Decodable, Hashable {
        struct Source: Decodable, Hashable {
            let type: String
            let messageID: String?
            let id: String?
        }

        let id: String
        let sessionID: String
        let action: String
        let resources: [String]
        let save: [String]?
        let metadata: JSONValue?
        let source: Source?
        let message: String?
    }

    // MARK: Models and providers

    struct ModelLimit: Decodable, Hashable {
        let context: Int
        let input: Int?
        let output: Int?
    }

    struct ModelVariant: Decodable, Hashable {
        let id: String
    }

    struct Model: Decodable, Hashable {
        let id: String
        let modelID: String?
        let providerID: String
        let name: String
        let family: String?
        let type: String?
        let variants: [ModelVariant]?
        let status: String?
        let enabled: Bool?
        let limit: ModelLimit?
    }

    struct Provider: Decodable, Hashable {
        let id: String
        let integrationID: String?
        let name: String
        let activation: String?
    }

    struct IntegrationMethod: Decodable, Hashable {
        let type: String
        let id: String?
        let label: String?
        let names: [String]?
    }

    struct IntegrationConnection: Decodable, Hashable {
        let type: String
        let id: String?
        let label: String?
        let name: String?
        let method: String?
    }

    struct Integration: Decodable, Hashable {
        let id: String
        let name: String
        let methods: [IntegrationMethod]
        let connections: [IntegrationConnection]
    }

    /// A stored credential. The secret value is deliberately not decoded.
    struct Credential: Decodable, Hashable {
        let id: String
        let integrationID: String
        let label: String?
        let active: Bool?
    }

    // MARK: Panels

    struct McpServer: Decodable, Hashable {
        struct Status: Decodable, Hashable {
            let status: String
            let error: String?
        }

        let name: String
        let status: Status
        let title: String?
        let integrationID: String?
    }

    struct FileDiff: Decodable, Hashable {
        let file: String
        let patch: String?
        let additions: Int?
        let deletions: Int?
        let status: String?
    }

    // MARK: Schedules

    struct ScheduleWhen: Decodable, Hashable {
        let type: String
        let cron: String?
        let every: String?
        let at: String?
        let `in`: String?
        let tz: String?
    }

    struct ScheduleAction: Decodable, Hashable {
        let type: String
        let prompt: String?
    }

    struct Schedule: Decodable, Hashable {
        let id: String
        let sessionID: String?
        let name: String?
        let when: ScheduleWhen
        let tz: String?
        let action: ScheduleAction?
        let status: String
        let nextDueAt: Double?
        let runCount: Int?
    }

    // MARK: Errors

    /// Error bodies look like `{"_tag": "ForbiddenError", "message": "..."}`.
    struct ErrorBody: Decodable {
        let tag: String?
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case message
        }
    }
}

extension Wire {
    static func date(_ milliseconds: Double?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
