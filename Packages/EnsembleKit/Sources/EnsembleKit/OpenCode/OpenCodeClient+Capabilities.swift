import Foundation

// MARK: Fork and rewind

extension OpenCodeClient: EngineHistoryControl {
    /// OpenCode restores the files the agent changed after the rewind point (checked live: the snapshot from before
    /// that message is put back on disk).
    public var rewindRestoresFiles: Bool { true }

    /// `POST /api/session/{id}/fork` copies the history *before* a message, so forking "through" a message passes
    /// the message after it. The fork is a new top-level session (no `parentID`) titled "<title> (fork #N)", in the
    /// same folder, with the same model and permission rules, and new message ids.
    public func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        var body: [String: JSONValue] = [:]
        if let messageID {
            let ids = try await messages(sessionID).map(\.id)
            guard let index = ids.firstIndex(of: messageID) else {
                throw OpenCodeError.invalidArgument("Message \(messageID) is not in session \(sessionID).")
            }
            if let next = HistoryBoundary.messageAfter(index, in: ids) { body["before"] = .string(next) }
        }
        let response: Wire.DataEnvelope<Wire.Session> = try await send("POST", "/api/session/\(sessionID)/fork", body: .object(body))
        return EngineSession(wire: response.data)
    }

    /// Stages a revert at `messageID` with its file changes (`files: true` restores the files on disk), then commits
    /// it, which removes `messageID` and every later message. If the commit fails the staged revert is cleared.
    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws {
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/revert/stage",
                                   body: ["messageID": .string(messageID), "files": true])
        do {
            try await sendIgnoringBody("POST", "/api/session/\(sessionID)/revert/commit")
        } catch {
            try? await sendIgnoringBody("DELETE", "/api/session/\(sessionID)/revert")
            throw error
        }
    }
}

enum HistoryBoundary {
    /// The id to pass as `before` so the fork keeps everything up to and including `ids[index]`; nil copies all.
    static func messageAfter(_ index: Int, in ids: [String]) -> String? {
        index + 1 < ids.count ? ids[index + 1] : nil
    }
}

// MARK: Effort and fast mode

/// Maps OpenCode model variants to Ensemble's effort levels and fast mode.
///
/// OpenCode exposes effort as named variants of a model (`low`, `medium`, `high`, `xhigh`, `max`, also `none` and
/// `minimal` on some models), each carrying provider settings such as `reasoningEffort`. A session runs one variant
/// at a time (`providerID/modelID#variant`). No 2.3 model offers a fast mode as such; a variant named `fast` is
/// treated as one if a provider ever adds it.
enum ModelVariantMapping {
    static func effort(forVariant variant: Wire.ModelVariant) -> EffortLevel? {
        if let level = effort(named: variant.id) { return level }
        // Variants with their own names but a standard effort setting.
        for key in ["reasoningEffort", "reasoning_effort", "effort"] {
            if let value = variant.settings?[key]?.stringValue, let level = effort(named: value) { return level }
        }
        return nil
    }

    static func effort(named name: String) -> EffortLevel? {
        switch name.lowercased() {
        case "low": .low
        case "medium": .medium
        case "high": .high
        case "xhigh", "extra-high", "extra_high": .xhigh
        case "max", "maximum": .max
        default: nil
        }
    }

    static let fastVariantNames: Set<String> = ["fast"]

    static func options(for model: Wire.Model) -> ModelOptions {
        let variants = model.variants ?? []
        var levels = Set<EffortLevel>()
        for variant in variants {
            if let level = effort(forVariant: variant) { levels.insert(level) }
        }
        let ordered = EffortLevel.allCases.filter { levels.contains($0) }
        let fast = variants.contains { fastVariantNames.contains($0.id.lowercased()) }
        // The engine does not say which effort the provider uses without a variant, so there is no default.
        return ModelOptions(effortLevels: ordered, defaultEffort: nil, supportsFastMode: fast)
    }

    /// The variant id to select for an effort, preferring a variant named after it.
    static func variantID(for effort: EffortLevel, in model: Wire.Model) -> String? {
        let variants = model.variants ?? []
        if let named = variants.first(where: { Self.effort(named: $0.id) == effort }) { return named.id }
        return variants.first { self.effort(forVariant: $0) == effort }?.id
    }

    static func fastVariantID(in model: Wire.Model) -> String? {
        (model.variants ?? []).first { fastVariantNames.contains($0.id.lowercased()) }?.id
    }
}

extension OpenCodeClient: EngineModelOptionsControl {
    public func modelOptions(for model: ModelRef) async throws -> ModelOptions {
        guard let wire = try await findModel(model, directory: defaultDirectory) else { return ModelOptions() }
        return ModelVariantMapping.options(for: wire)
    }

    /// Switches the session to the model's variant for `effort` (no variant when `nil`).
    public func setEffort(_ sessionID: String, effort: EffortLevel?) async throws {
        let (current, model) = try await sessionModel(sessionID)
        var ref = current
        if let effort {
            guard let variant = ModelVariantMapping.variantID(for: effort, in: model) else {
                throw OpenCodeError.invalidArgument("\(model.name) has no \(effort.label) effort setting.")
            }
            ref.variant = variant
        } else {
            ref.variant = nil
        }
        try await switchModel(sessionID, model: ref)
    }

    /// Selects the model's `fast` variant, or goes back to no variant. Throws when the model has no fast mode.
    public func setFastMode(_ sessionID: String, enabled: Bool) async throws {
        let (current, model) = try await sessionModel(sessionID)
        guard let fast = ModelVariantMapping.fastVariantID(in: model) else {
            if !enabled { return }
            throw OpenCodeError.invalidArgument("\(model.name) has no fast mode.")
        }
        var ref = current
        if enabled {
            ref.variant = fast
        } else if ref.variant == fast {
            ref.variant = nil
        } else {
            return
        }
        try await switchModel(sessionID, model: ref)
    }

    private func sessionModel(_ sessionID: String) async throws -> (ModelRef, Wire.Model) {
        let response: Wire.DataEnvelope<Wire.Session> = try await get("/api/session/\(sessionID)")
        let session = response.data
        let ref: ModelRef
        if let model = session.model {
            ref = ModelRef(wire: model)
        } else if let fallback = try await defaultModel(directory: session.location?.directory) {
            ref = fallback
        } else {
            throw OpenCodeError.invalidArgument("Session \(sessionID) has no model.")
        }
        guard let model = try await findModel(ref, directory: session.location?.directory) else {
            throw OpenCodeError.invalidArgument("Model \(ref) is not available.")
        }
        return (ref, model)
    }

    /// Looks in `directory` first (project config can add providers), then in the other loaded folders.
    private func findModel(_ ref: ModelRef, directory: String?) async throws -> Wire.Model? {
        func match(_ models: [Wire.Model]) -> Wire.Model? {
            models.first { $0.providerID == ref.providerID && $0.id == ref.id }
        }
        if let found = match(try await wireModels(directory: directory)) { return found }
        for other in (try? await loadedDirectories()) ?? [] where other != directory {
            if let found = match((try? await wireModels(directory: other)) ?? []) { return found }
        }
        return nil
    }
}

// MARK: Slash commands and skills

enum CommandMapping {
    /// OpenCode's command descriptions put the arguments in brackets, e.g. "review changes [commit|branch|pr]".
    static func argumentHint(from description: String?) -> String? {
        guard let description, let open = description.firstIndex(of: "["),
              let close = description[open...].firstIndex(of: "]") else { return nil }
        return String(description[open...close])
    }

    static func commands(_ commands: [Wire.Command], skills: [Wire.Skill]) -> [EngineCommand] {
        let fromCommands = commands.map {
            EngineCommand(name: $0.name, summary: $0.description ?? "", kind: .command, argumentHint: argumentHint(from: $0.description))
        }
        let taken = Set(fromCommands.map(\.name))
        let fromSkills = skills.filter { !taken.contains($0.id) }.map {
            EngineCommand(name: $0.id, summary: $0.description ?? $0.name ?? "", kind: .skill)
        }
        return fromCommands + fromSkills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension OpenCodeClient: EngineCommandsControl {
    /// `GET /api/command` (built-in and configured commands such as `init`, `review`, `goal`) and `GET /api/skill`.
    public func commands(directory: String?) async throws -> [EngineCommand] {
        let location = Self.location(directory ?? defaultDirectory)
        async let commandList: Wire.LocationEnvelope<[Wire.Command]> = get("/api/command", query: location)
        async let skillList: Wire.LocationEnvelope<[Wire.Lossy<Wire.Skill>]> = get("/api/skill", query: location)
        let commands = try await commandList.data
        let skills = ((try? await skillList.data) ?? []).compactMap(\.value)
        return CommandMapping.commands(commands, skills: skills)
    }

    /// Runs a command with `POST /api/session/{id}/command`, or activates a skill with
    /// `POST /api/experimental/session/{id}/skill` and then sends `arguments` (if any) as the prompt.
    public func runCommand(_ sessionID: String, name: String, arguments: String) async throws {
        let trimmedName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let session = try await self.session(sessionID)
        let available = try await commands(directory: session.directory.isEmpty ? nil : session.directory)
        let match = available.first { $0.kind == .command && $0.name == trimmedName }
            ?? available.first { $0.name == trimmedName }
        guard let match else { throw OpenCodeError.invalidArgument("There is no /\(trimmedName) command or skill.") }
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        switch match.kind {
        case .command:
            try await sendIgnoringBody("POST", "/api/session/\(sessionID)/command",
                                       body: ["name": .string(match.name), "text": .string(text)])
        case .skill:
            try await sendIgnoringBody("POST", "/api/experimental/session/\(sessionID)/skill",
                                       body: ["id": .string(match.name), "resume": .bool(text.isEmpty)])
            if !text.isEmpty { try await prompt(sessionID, text: text, files: []) }
        }
    }
}
