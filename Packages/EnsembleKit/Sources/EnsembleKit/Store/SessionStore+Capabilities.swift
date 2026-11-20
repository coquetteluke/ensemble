import Foundation

/// Optional engine abilities (see `EngineCapabilities.swift`): history, effort and fast mode, slash commands.
/// Each is used only when the engine conforms; the UI disables or hides the controls otherwise.
extension SessionStore {
    // MARK: History: fork, rewind, edit

    public var historyControl: (any EngineHistoryControl)? { engine as? any EngineHistoryControl }
    public var supportsHistory: Bool { historyControl != nil }

    /// Copies the session (up to and including `messageID`, or all of it) into a new session and opens it.
    @discardableResult
    public func fork(_ sessionID: String, atMessageID messageID: String?) async -> SessionModel? {
        let primaryID = primarySessionID(for: sessionID)
        guard let history = historyControl, let source = byID[primaryID] else { return nil }
        if threadLinks.hasLinks(for: primaryID) {
            lastError = "Fork is not available after switching engines in a thread."
            return nil
        }
        do {
            var engineID: String?
            if let messageID { engineID = try await engineMessageID(for: messageID, in: source) }
            let info = try await history.fork(primaryID, atMessageID: engineID)
            let session = upsertSession(info)
            session.permissionMode = source.permissionMode
            select(session.id)
            return session
        } catch {
            lastError = "Could not fork: \(error.localizedDescription)"
            return nil
        }
    }

    /// Removes `messageID` and everything after it, then reloads the transcript.
    @discardableResult
    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async -> Bool {
        let primaryID = primarySessionID(for: sessionID)
        guard let history = historyControl, let session = byID[primaryID] else { return false }
        if threadLinks.hasLinks(for: primaryID) {
            lastError = "Rewind is not available after switching engines in a thread."
            return false
        }
        do {
            guard let engineID = try await engineMessageID(for: messageID, in: session) else { return false }
            try await history.rewind(primaryID, toBeforeMessageID: engineID)
            // Prompts after the rewind point are gone; take the engine's list rather than the old one.
            if let pending = try? await engine.pendingPermissions() {
                session.pendingPermissions = pending.filter { primarySessionID(for: $0.sessionID) == session.id }
            }
            session.transcriptLoaded = false
            await loadSession(primaryID)
            return true
        } catch {
            lastError = "Could not rewind: \(error.localizedDescription)"
            return false
        }
    }

    /// Rewinds to before a message of yours and returns its text, for the composer to resend.
    public func editMessage(_ sessionID: String, messageID: String) async -> String? {
        guard let session = byID[sessionID],
              let text = session.items.compactMap({ item -> String? in
                  if case .user(let id, let text, _) = item, id == messageID { return text }
                  return nil
              }).first else { return nil }
        return await rewind(sessionID, toBeforeMessageID: messageID) ? text : nil
    }

    /// Messages sent from this app carry a local id until the transcript is reloaded. Maps such an id
    /// to the engine's id by its position among your messages.
    func engineMessageID(for messageID: String, in session: SessionModel) async throws -> String? {
        guard messageID.hasPrefix("user-") else { return messageID }
        let localUsers = session.items.compactMap { item -> String? in
            if case .user(let id, _, _) = item { return id }
            return nil
        }
        guard let position = localUsers.firstIndex(of: messageID) else { return nil }
        let fresh = try await engine.transcript(session.id)
        let engineUsers = fresh.compactMap { item -> String? in
            if case .user(let id, _, _) = item { return id }
            return nil
        }
        return position < engineUsers.count ? engineUsers[position] : nil
    }

    // MARK: Effort and fast mode

    public var modelOptionsControl: (any EngineModelOptionsControl)? { engine as? any EngineModelOptionsControl }

    /// Options for a model, or nil when the engine has no model options (or they are not loaded yet).
    public func options(for model: ModelRef?) -> ModelOptions? {
        guard modelOptionsControl != nil, let model else { return nil }
        return modelOptions[model.description]
    }

    public func loadModelOptions(for model: ModelRef?) async {
        guard let control = modelOptionsControl, let model, modelOptions[model.description] == nil else { return }
        if let options = try? await control.modelOptions(for: model) {
            modelOptions[model.description] = options
        }
    }

    public func setEffort(_ effort: EffortLevel?, for sessionID: String) async {
        guard let control = modelOptionsControl, let session = byID[sessionID] else { return }
        let previous = session.effort
        session.effort = effort
        do { try await control.setEffort(sessionID, effort: effort) } catch {
            session.effort = previous
            lastError = "Could not change effort: \(error.localizedDescription)"
        }
    }

    public func setFastMode(_ enabled: Bool, for sessionID: String) async {
        guard let control = modelOptionsControl, let session = byID[sessionID] else { return }
        let previous = session.fastMode
        session.fastMode = enabled
        do { try await control.setFastMode(sessionID, enabled: enabled) } catch {
            session.fastMode = previous
            lastError = "Could not change fast mode: \(error.localizedDescription)"
        }
    }

    // MARK: Slash commands

    public var commandsControl: (any EngineCommandsControl)? { engine as? any EngineCommandsControl }

    /// The `/` menu for a folder: Ensemble's commands plus the engine's (loaded with `loadCommands`).
    public func slashCommands(directory: String) -> [SlashCommand] {
        SlashCommands.catalog(engine: engineCommands[directory] ?? [])
    }

    public func loadCommands(directory: String) async {
        guard let control = commandsControl, engineCommands[directory] == nil else { return }
        if let list = try? await control.commands(directory: directory) {
            engineCommands[directory] = list
        }
    }

    /// True when the engine offers a command with this name for the session's folder.
    public func engineHasCommand(_ name: String, sessionID: String) -> Bool {
        guard let session = byID[sessionID] else { return false }
        return engineCommands[session.directory]?.contains { $0.name == name } ?? false
    }

    /// Runs one of the engine's slash commands in a session.
    public func runCommand(_ name: String, arguments: String, in sessionID: String) async {
        guard let control = commandsControl, let session = byID[sessionID] else { return }
        let shown = arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)"
        session.items.append(.user(id: "user-\(UUID().uuidString)", text: shown, date: Date()))
        session.setActivity(.working)
        session.info.updated = Date()
        session.touch()
        do {
            try await control.runCommand(sessionID, name: name, arguments: arguments)
        } catch {
            session.items.append(.error(id: "error-\(UUID().uuidString)", message: "Could not run /\(name): \(error.localizedDescription)"))
            session.setActivity(.failed)
            session.touch()
        }
    }

    // MARK: Notices

    /// Adds a grey status line to a session's transcript (local only).
    public func addNotice(_ text: String, to sessionID: String) {
        guard let session = byID[sessionID] else { return }
        session.items.append(.notice(id: "notice-\(UUID().uuidString)", text: text))
        session.touch()
    }
}
