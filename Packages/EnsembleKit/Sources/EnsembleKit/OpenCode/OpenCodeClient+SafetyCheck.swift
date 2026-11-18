import Foundation

// What the safety check for Auto (`Store/SafetyCheck.swift`) needs from OpenCode.
//
// - The model call is `POST /api/experimental/generate/text` (`{"prompt", "model"}` in, `{"data": {"text"}}` out): one
//   stateless generation with the server's base configuration, no session, no tools and no system prompt (checked with
//   the mock model: the provider receives the prompt as the only message). It does not report tokens.
// - `permission.asked` names its tool call in `source.id` (the same id as the tool card); the store's prompt model does
//   not keep it, so it is read back with `GET /api/session/{id}/permission/{requestID}`.
// - Prices come from `GET /api/model` (`cost[0].input` and `.output`, US dollars per million tokens).
extension OpenCodeClient: EngineSafetyCheckSupport {
    public func safetyCheckApplies(to sessionID: String) -> Bool { true }

    public func toolCallID(forPermission requestID: String, sessionID: String) async -> String? {
        let response: Wire.DataEnvelope<Wire.PermissionRequest>? = try? await get(
            "/api/session/\(Self.pathComponent(sessionID))/permission/\(Self.pathComponent(requestID))")
        guard let source = response?.data.source, source.type == "tool" else { return nil }
        return source.id
    }

    public func generateSafetyCheckText(prompt: String, model: ModelRef) async throws -> String {
        let body: JSONValue = ["prompt": .string(prompt), "model": try JSONValue(encoding: model.wire)]
        let response: Wire.DataEnvelope<SafetyCheckWire.GeneratedText> = try await send(
            "POST", "/api/experimental/generate/text", body: body)
        return response.data.text
    }

    public func safetyCheckModels() async throws -> [SafetyCheckModel] {
        async let providerList: Wire.LocationEnvelope<[Wire.Provider]> = get("/api/provider", query: Self.location(defaultDirectory))
        let response: Wire.LocationEnvelope<[SafetyCheckWire.PricedModel]> = try await get(
            "/api/model", query: Self.location(defaultDirectory))
        let names = Dictionary(((try? await providerList.data) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return response.data.compactMap { model in
            guard model.enabled != false, model.status != "deprecated", model.type == nil || model.type == "chat" else { return nil }
            let price = model.cost?.first
            return SafetyCheckModel(ref: ModelRef(providerID: model.providerID, id: model.id), name: model.name,
                                    providerName: names[model.providerID], inputCostPerMillion: price?.input ?? 0,
                                    outputCostPerMillion: price?.output ?? 0)
        }
    }
}

/// Wire shapes only the safety check reads.
enum SafetyCheckWire {
    struct GeneratedText: Decodable {
        let text: String
    }

    struct Price: Decodable {
        let input: Double?
        let output: Double?
    }

    struct PricedModel: Decodable {
        let id: String
        let providerID: String
        let name: String
        let type: String?
        let status: String?
        let enabled: Bool?
        let cost: [Price]?
    }
}
