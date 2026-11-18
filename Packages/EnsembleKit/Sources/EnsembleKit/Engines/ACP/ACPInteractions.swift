import Foundation

/// An ACP `elicitation/create` request in form mode, read as questions. agy 1.5.10 sends one when its `ask_question`
/// tool runs and the client advertises `elicitation.form` (tested 2026-11-18; without the capability it prints the
/// question as text instead). Its schema has a property per question, `q1`, `q2`, ...: a string with `oneOf`
/// (`const` and `title`) for a single choice, an array whose `items` have `anyOf` for several, plus `q1_other`, an
/// optional free-text answer. The answer is `{"action": "accept", "content": {"q1": "2", "q2": ["1", "3"], "q1_other":
/// "..."}}`; `{"action": "decline"}` declines and `{"action": "cancel"}` withdraws it. Other agents' simple schemas
/// (plain strings, `enum`, booleans, numbers) are read the same way.
struct ACPElicitation: Equatable, Sendable {
    enum FieldKind: Equatable, Sendable {
        case single, multi, text, boolean, number
    }

    struct Field: Equatable, Sendable {
        var key: String
        var kind: FieldKind
        /// The property that takes a typed answer to this question (`q1_other`), if any.
        var otherKey: String?
    }

    var message: String?
    var questions: [AgentQuestion]
    var fields: [String: Field]

    /// Reads the request's parameters; nil for URL-mode requests and schemas without anything to answer.
    init?(params: JSONValue) {
        if let mode = params["mode"]?.stringValue, mode != "form" { return nil }
        guard let properties = params["requestedSchema"]?["properties"]?.objectValue, !properties.isEmpty else { return nil }
        message = params["message"]?.stringValue
        let keys = properties.keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        var questions: [AgentQuestion] = []
        var fields: [String: Field] = [:]
        for key in keys {
            // A `<key>_other` property belongs to `<key>` when that exists.
            if key.hasSuffix("_other"), properties[String(key.dropLast("_other".count))] != nil { continue }
            guard let schema = properties[key], let parsed = Self.question(key: key, schema: schema) else { continue }
            var question = parsed.question
            let otherKey = properties["\(key)_other"] != nil ? "\(key)_other" : nil
            if otherKey != nil { question.allowsOther = true }
            questions.append(question)
            fields[key] = Field(key: key, kind: parsed.kind, otherKey: otherKey)
        }
        guard !questions.isEmpty else { return nil }
        self.questions = questions
        self.fields = fields
    }

    private static func question(key: String, schema: JSONValue) -> (question: AgentQuestion, kind: FieldKind)? {
        let title = schema["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let description = schema["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let text = title ?? description ?? key
        let header = title != nil ? nil : description
        switch schema["type"]?.stringValue {
        case "string":
            let options = choices(schema)
            if options.isEmpty {
                return (AgentQuestion(id: key, header: header, text: text, options: [], allowsOther: true), .text)
            }
            return (AgentQuestion(id: key, header: header, text: text, options: options, allowsOther: false), .single)
        case "array":
            let options = choices(schema["items"] ?? .null)
            guard !options.isEmpty else { return nil }
            return (AgentQuestion(id: key, header: header, text: text, options: options, multiSelect: true, allowsOther: false), .multi)
        case "boolean":
            return (AgentQuestion(id: key, header: header, text: text,
                                  options: [.init(label: "Yes", value: "true"), .init(label: "No", value: "false")],
                                  allowsOther: false), .boolean)
        case "number", "integer":
            return (AgentQuestion(id: key, header: header, text: text, options: [], allowsOther: true), .number)
        default:
            return nil
        }
    }

    /// Options from `oneOf`/`anyOf` (`const` with `title`) or `enum` (with `enumNames` when given).
    private static func choices(_ schema: JSONValue) -> [AgentQuestion.Option] {
        if let list = schema["oneOf"]?.arrayValue ?? schema["anyOf"]?.arrayValue {
            return list.compactMap { entry in
                guard let value = entry["const"]?.acpText else { return nil }
                let label = entry["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? value
                return AgentQuestion.Option(label: label, detail: entry["description"]?.stringValue, value: value == label ? nil : value)
            }
        }
        let values = (schema["enum"]?.arrayValue ?? []).compactMap(\.acpText)
        let names = (schema["enumNames"]?.arrayValue ?? []).compactMap(\.stringValue)
        return values.enumerated().map { index, value in
            let label = index < names.count && !names[index].isEmpty ? names[index] : value
            return AgentQuestion.Option(label: label, value: value == label ? nil : value)
        }
    }

    /// The `content` of an accepting answer. Unanswered questions are left out.
    func content(for answers: [AgentQuestionAnswer]) -> [String: JSONValue] {
        var content: [String: JSONValue] = [:]
        for question in questions {
            guard let field = fields[question.id],
                  let answer = answers.first(where: { $0.questionID == question.id }).flatMap(question.validated) else { continue }
            let values = answer.selected.compactMap(question.value(forLabel:))
            switch field.kind {
            case .single:
                if let value = values.first { content[field.key] = .string(value) }
            case .multi:
                if !values.isEmpty { content[field.key] = .array(values.map(JSONValue.string)) }
            case .boolean:
                if let value = values.first { content[field.key] = .bool(value == "true") }
            case .number:
                if let text = answer.other, let number = Double(text) { content[field.key] = .number(number) }
            case .text:
                if let text = answer.other { content[field.key] = .string(text) }
            }
            if field.kind != .text, field.kind != .number, let otherKey = field.otherKey, let other = answer.other {
                content[otherKey] = .string(other)
            }
        }
        return content
    }

    /// The JSON-RPC result: accept with the answers, or decline when there are none.
    func result(for answers: [AgentQuestionAnswer]) -> JSONValue {
        let content = content(for: answers)
        guard !content.isEmpty else { return Self.declined }
        return ["action": "accept", "content": .object(content)]
    }

    static let declined: JSONValue = ["action": "decline"]
    static let cancelled: JSONValue = ["action": "cancel"]
}

/// agy's plan: in its `plan` mode it writes an implementation plan with `write_file` into its own artifact folder
/// (`~/.gemini/antigravity-cli/brain/<conversation>/`, no prompt), marks it `ArtifactMetadata.RequestFeedback`, and ends
/// the turn asking for "Proceed" (tested 2026-11-18 with gemini-3.8-flash-low). Ensemble shows that file's content as
/// the plan card when the turn ends; Proceed sets the chosen mode and sends a message, as the agent asks.
enum ACPPlanArtifact {
    /// The plan in a tool call's input, if the call writes a plan artifact that asks for review.
    static func plan(in rawInput: JSONValue?) -> PlanProposal? {
        guard let rawInput, case .bool(true)? = rawInput["ArtifactMetadata"]?["RequestFeedback"],
              let content = rawInput["Content"]?.stringValue ?? rawInput["content"]?.stringValue,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let path = rawInput["Path"]?.stringValue ?? rawInput["path"]?.stringValue
        return PlanProposal(markdown: content, filePath: path)
    }

    /// The last agent text since the last user message, for agents that write their plan as a reply.
    static func lastReply(in items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            switch item {
            case .agentText(_, let text, _, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .user:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
