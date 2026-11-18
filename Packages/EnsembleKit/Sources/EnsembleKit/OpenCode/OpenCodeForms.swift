import Foundation

/// OpenCode 2.3 questions. The `question` tool (and anything else that needs input) opens a form: a `form.created` event
/// with `fields`, answered with `POST /api/session/{id}/form/{formID}/reply` `{"answer": {key: value}}` and declined with
/// `DELETE /api/session/{id}/form/{formID}`; `form.replied` or `form.cancelled` follows. The turn waits meanwhile.
/// Checked live 2026-11-18 with the mock model: one question with two options became a `string` field with `options`
/// and `custom: true`, its key `q0`; the reply `{"q0": "Blue"}` reached the agent as `"Which color?"="Blue"`.
/// Open forms are listed per project folder (`GET /api/form`, location-scoped) and per session.
enum OpenCodeForms {
    struct Form: Decodable, Hashable {
        let id: String
        let sessionID: String
        let title: String?
        let metadata: JSONValue?
        let fields: [JSONValue]
    }

    struct Detail: Decodable {
        struct State: Decodable { let status: String }
        let id: String
        let sessionID: String
        let fields: [JSONValue]
        let state: State?
    }

    /// The request Ensemble shows for a form, or nil when it has nothing Ensemble can answer (only links to open, or
    /// hidden fields).
    static func request(_ form: Form, created: Date = Date()) -> PermissionRequest? {
        let questions = form.fields.compactMap(question)
        guard !questions.isEmpty, questions.count == answerableCount(form.fields) else { return nil }
        return PermissionRequest(id: form.id, sessionID: form.sessionID, kind: InteractionKind.question,
                                 title: questions[0].text, created: created, questions: questions)
    }

    /// Fields the user must answer: everything except hidden ones.
    private static func answerableCount(_ fields: [JSONValue]) -> Int {
        fields.filter { field in
            if case .bool(true)? = field["hidden"] { return false }
            return true
        }.count
    }

    /// One field as a question. Links to open elsewhere (`external`) are not questions.
    static func question(_ field: JSONValue) -> AgentQuestion? {
        guard let key = field["key"]?.stringValue, !key.isEmpty, let type = field["type"]?.stringValue else { return nil }
        if case .bool(true)? = field["hidden"] { return nil }
        let title = field["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let description = field["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let text = description ?? title ?? key
        let header = description != nil ? title : nil
        var custom = false
        if case .bool(true)? = field["custom"] { custom = true }
        let options = (field["options"]?.arrayValue ?? []).compactMap { option -> AgentQuestion.Option? in
            guard let value = option["value"]?.stringValue else { return nil }
            let label = option["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? value
            return AgentQuestion.Option(label: label, detail: option["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                                        value: value == label ? nil : value)
        }
        switch type {
        case "string":
            return AgentQuestion(id: key, header: header, text: text, options: options, multiSelect: false,
                                 allowsOther: options.isEmpty || custom)
        case "multiselect":
            return AgentQuestion(id: key, header: header, text: text, options: options, multiSelect: true, allowsOther: custom)
        case "boolean":
            return AgentQuestion(id: key, header: header, text: text,
                                 options: [.init(label: "Yes", value: "true"), .init(label: "No", value: "false")],
                                 multiSelect: false, allowsOther: false)
        case "number", "integer":
            return AgentQuestion(id: key, header: header, text: text, options: [], multiSelect: false, allowsOther: true)
        default:
            return nil
        }
    }

    /// The `answer` object for a reply, built against the form's own fields (fetched again just before replying), so
    /// each value has the type its field expects. Fields left unanswered are left out.
    static func answer(fields: [JSONValue], questions: [AgentQuestion], answers: [AgentQuestionAnswer]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in fields {
            guard let key = field["key"]?.stringValue, let type = field["type"]?.stringValue,
                  let question = questions.first(where: { $0.id == key }),
                  let answer = answers.first(where: { $0.questionID == key }).flatMap(question.validated) else { continue }
            let values = answer.selected.compactMap(question.value(forLabel:))
            switch type {
            case "multiselect":
                result[key] = .array((values + [answer.other].compactMap { $0 }).map(JSONValue.string))
            case "boolean":
                if let value = values.first { result[key] = .bool(value == "true") }
            case "number", "integer":
                if let text = answer.other, let number = Double(text) {
                    result[key] = .number(type == "integer" ? number.rounded(.towardZero) : number)
                }
            default:
                if let value = values.first ?? answer.other { result[key] = .string(value) }
            }
        }
        return result
    }
}
