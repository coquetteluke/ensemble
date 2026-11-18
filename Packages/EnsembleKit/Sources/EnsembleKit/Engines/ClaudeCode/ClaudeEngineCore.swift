#if os(macOS)
import Foundation

/// The Claude engine's state: saved sessions, running `claude` processes, open permission prompts.
actor ClaudeEngineCore {
    struct Live {
        var process: ClaudeProcess
        var decoder: ClaudeStreamDecoder
        var bypassAllowed: Bool
        /// Prompts written and not yet answered by a `result` line.
        var turnsInFlight = 0
        /// Restart with the saved settings once idle (a change the running process cannot take live).
        var restartWhenIdle = false
        var interrupting = false
        /// The process was started with `--resume-session-at`; cleared after its first turn.
        var launchedWithResumeAt = false
        /// Whether the folder was trusted (project settings loaded) when the process started.
        var trusted = false
        /// The CLI reads the project's own settings files (`ClaudeSettingsPlan.project`), so they are watched.
        var readsProjectFiles = false
        /// The `permissions` of the process's `--settings` file, sent back unchanged around the plan guard.
        var basePermissions: JSONValue?
        /// The CLI confirmed the plan guard's ask rules (`ClaudePlanGuard`). No turn is sent in plan until it has.
        var planGuardOn = false
    }

    struct TranscriptSource: Sendable {
        var file: URL?
        var leafOverride: String?
        var builder: ClaudeTranscriptBuilder
    }

    struct FileSource: Sendable {
        var file: URL
        var leafOverride: String?
        var builder: ClaudeTranscriptBuilder
    }

    let configuration: ClaudeCodeEngine.Configuration
    let broadcaster: ClaudeEventBroadcaster
    let files: ClaudeTranscriptFiles
    let keychain: ClaudeKeychain

    private var store: ClaudeSessionStore
    private var live: [String: Live] = [:]
    private var pending: [String: ClaudePermissionPrompt] = [:]
    private var rules: [String: ClaudePermissionRules] = [:]
    private var waiters: [String: (root: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var generation = 0
    private var planLimits: ClaudePlanLimits?
    private var connectors: [ConnectorInfo] = []
    private var contextWindows: [String: Int] = [:]
    private var children: [String: EngineSession] = [:]
    private var initializeInfo: ClaudeInitializeInfo?
    private var commandCache: [String: (date: Date, info: ClaudeInitializeInfo)] = [:]
    private var skillsByDirectory: [String: Set<String>] = [:]
    private var terminalCommands: Set<String> = ["doctor", "color", "focus", "reload-plugins"]
    private var authCache: (date: Date, state: ClaudeAuthState)?
    /// What Redo needs to undo each session's last rewind, until its next prompt.
    private var rewindUndo: [String: ClaudeRewindUndo] = [:]

    init(configuration: ClaudeCodeEngine.Configuration, broadcaster: ClaudeEventBroadcaster) {
        self.configuration = configuration
        self.broadcaster = broadcaster
        files = ClaudeTranscriptFiles(projectsDirectory: configuration.projectsDirectory)
        keychain = ClaudeKeychain(service: configuration.keychainService)
        store = ClaudeSessionStore(fileURL: configuration.storeURL)
    }

    // MARK: Helpers

    func executableURL() -> URL? {
        ClaudeCLI.locate(override: configuration.executablePath, environment: configuration.baseEnvironment)
    }

    private func save() {
        try? store.save()
    }

    private func emit(_ event: EngineEvent) {
        broadcaster.yield(event)
    }

    private func record(_ id: String) throws -> ClaudeSessionRecord {
        guard let record = store[id] else { throw ClaudeCodeError.unknownSession(id) }
        return record
    }

    private func rootRecord(_ id: String, action: String) throws -> ClaudeSessionRecord {
        if ClaudeSessionIDs.isChild(id) {
            throw ClaudeCodeError.notSupported("A subagent cannot \(action). Use its parent session.")
        }
        return try record(id)
    }

    private static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "..." : trimmed
    }

    func currentPlanLimits() -> ClaudePlanLimits? { planLimits }

    /// Confirms the folder's current settings (all of them, as `ClaudeProjectSettings.Snapshot` reads them). Any later
    /// change to them needs a new confirmation before the next launch.
    func confirmProjectAPISettings(directory: String) throws {
        guard configuration.trust.isTrusted(directory) else { throw ClaudeCodeError.folderNotTrusted(directory) }
        let key = WorkspaceTrust.resolvedPath(directory) ?? directory
        guard let snapshot = ClaudeProjectSettings.snapshot(directory: directory),
              !snapshot.needsConfirmation(for: .apiKey).isEmpty else {
            store.confirmedAPISettings[key] = nil
            save()
            return
        }
        store.confirmedAPISettings[key] = snapshot.fingerprint
        save()
    }

    /// The settings plan for a session folder right now (throws when the user has to trust or confirm first).
    private func settingsPlan(directory: String, billing: ClaudeBilling, trusted: Bool) throws -> ClaudeSettingsPlan {
        let key = WorkspaceTrust.resolvedPath(directory) ?? directory
        return try ClaudeSettingsPlan.decide(billing: billing, trusted: trusted, directory: directory,
                                             snapshot: ClaudeProjectSettings.snapshot(directory: directory),
                                             confirmed: store.confirmedAPISettings[key])
    }

    /// Why a process that reads a trusted folder's own files must stop now, or nil. The pinned keys cannot take
    /// effect (`ClaudeProjectSettings.loginPins`), so only what the pins do not cover counts, unless the user confirmed
    /// exactly these files.
    private func projectFilesProblem(_ record: ClaudeSessionRecord) -> ClaudeCodeError? {
        guard configuration.trust.isTrusted(record.directory) else { return .folderNotTrusted(record.directory) }
        guard let snapshot = ClaudeProjectSettings.snapshot(directory: record.directory) else {
            return .invalidArgument("The project folder can no longer be read: \(record.directory)")
        }
        let unpinned = snapshot.unpinnedRedirects
        let key = WorkspaceTrust.resolvedPath(record.directory) ?? record.directory
        guard !unpinned.isEmpty, store.confirmedAPISettings[key] != snapshot.fingerprint else { return nil }
        return .projectOverridesAPISettings(directory: record.directory, keys: unpinned)
    }

    /// Called about once a second while the CLI reads a trusted folder's own settings files (the CLI reloads them while
    /// it runs). When they now hold something the pins do not cover, the process is stopped at once. Returns false
    /// when there is nothing left to watch.
    private func watchProjectSettings(root: String, generation: Int) -> Bool {
        guard let session = live[root], session.process.generation == generation, session.readsProjectFiles,
              let record = store[root] else { return false }
        if let error = projectFilesProblem(record) {
            live[root] = nil
            session.process.terminate()
            failWaiters(root: root, message: "the project's Claude settings changed")
            clearPending(root: root)
            if session.turnsInFlight > 0 {
                emit(.executionEnded(sessionID: root, outcome: "failed", error: error.localizedDescription))
                emit(.activity(sessionID: root, .failed))
            }
            emit(.other(type: "claude.project_settings_changed"))
            return false
        }
        return true
    }
    func currentConnectors() -> [ConnectorInfo] { connectors }

    // MARK: Sign-in

    func authState(refresh: Bool) async -> ClaudeAuthState {
        if !refresh, let cached = authCache, Date().timeIntervalSince(cached.date) < 60 { return cached.state }
        guard let exe = executableURL() else {
            let state = ClaudeAuthState(installed: false)
            authCache = (Date(), state)
            return state
        }
        let env = ClaudeCLI.environment(base: configuration.baseEnvironment, billing: .subscription, apiKey: nil)
        let versionText = await ClaudeCommand.run(exe, ["--version"], environment: env)
        let version = versionText?.split(separator: " ").first.map(String.init)
        // `claude auth status` is the CLI's own check; Ensemble keeps only loggedIn, the method and the plan type.
        let statusText = await ClaudeCommand.run(exe, ["auth", "status", "--json"], environment: env) ?? ""
        let state = ClaudeAuthState.parse(statusText, installed: true, version: version)
        authCache = (Date(), state)
        return state
    }

    // MARK: Sessions

    func listSessions() -> [EngineSession] {
        store.all.map(\.engineSession) + children.values.sorted { $0.created < $1.created }
    }

    func createSession(directory: String, model: ModelRef?, permissionMode: PermissionMode, parentID: String?) throws -> EngineSession {
        if parentID != nil {
            throw ClaudeCodeError.notSupported("Claude subagents are started by the agent itself (its Agent tool).")
        }
        if let model, !ClaudeModels.isClaudeProvider(model.providerID) {
            throw ClaudeCodeError.invalidArgument("\(model) is not a Claude model.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ClaudeCodeError.invalidArgument("The project folder does not exist: \(directory)")
        }
        let id = UUID().uuidString.lowercased()
        let record = ClaudeSessionRecord(id: id, title: "", directory: directory, model: model, permissionMode: permissionMode)
        store[id] = record
        save()
        emit(.sessionCreated(record.engineSession))
        return record.engineSession
    }

    /// Adds imported sessions (`ClaudeImport+Engine.swift`); ids already known, as a session or its CLI conversation, are skipped.
    func adopt(_ imported: [ClaudeSessionRecord]) -> [EngineSession] {
        var known = Set(store.all.flatMap { [$0.id, $0.cliID] })
        let added = imported.filter { known.insert($0.id).inserted }
        for record in added { store[record.id] = record }
        if !added.isEmpty { save() }
        for record in added { emit(.sessionCreated(record.engineSession)) }
        return added.map(\.engineSession)
    }

    func deleteSession(_ id: String) throws {
        _ = try rootRecord(id, action: "be deleted on its own")
        stopProcess(id)
        store.remove(id)
        rules[id] = nil
        for (childID, child) in children where ClaudeSessionIDs.root(of: childID) == id {
            children[childID] = nil
            emit(.sessionDeleted(sessionID: child.id))
        }
        save()
        emit(.sessionDeleted(sessionID: id))
    }

    func rename(_ id: String, title: String) throws {
        if ClaudeSessionIDs.isChild(id) {
            guard var child = children[id] else { return }
            child.title = title
            children[id] = child
            emit(.sessionUpdated(child))
            return
        }
        var record = try record(id)
        record.title = title
        record.updated = Date()
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
    }

    func setArchived(_ id: String, archived: Bool) throws {
        if ClaudeSessionIDs.isChild(id) {
            guard var child = children[id] else { return }
            child.archived = archived
            children[id] = child
            emit(.sessionUpdated(child))
            return
        }
        var record = try record(id)
        record.archived = archived
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
    }

    func setPermissionMode(_ id: String, mode: PermissionMode) async throws {
        var record = try rootRecord(id, action: "have its own permission mode")
        let previous = record.permissionMode
        record.permissionMode = mode
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        guard let session = live[id] else { return }
        if mode == .bypass && !session.bypassAllowed {
            // Bypass needs a process launched with --allow-dangerously-skip-permissions.
            restartWhenIdle(id)
            return
        }
        if mode == .plan {
            try await enterPlan(id, previous: previous)
            return
        }
        do {
            _ = try await control(id, ["subtype": "set_permission_mode", "mode": .string(ClaudePermissionModes.cliMode(mode))])
        } catch {
            restartWhenIdle(id)
            return
        }
        // Leaving plan: lift the guard. If that fails the extra ask rules stay, which only asks more, until the process
        // restarts.
        if live[id]?.planGuardOn == true {
            do { try await applyPlanGuard(id, planOn: false) } catch { restartWhenIdle(id) }
        }
    }

    /// Switches a running process to plan with the guard confirmed, or not at all. The guard goes on first and must be
    /// confirmed before the mode changes (its ask rules only make any mode ask more), so the CLI is never in plan without
    /// it. When either step fails, the CLI and the saved session go back to `previous`, a turn in progress is stopped,
    /// and the call throws.
    private func enterPlan(_ id: String, previous: PermissionMode) async throws {
        var reason: String?
        do {
            try await applyPlanGuard(id, planOn: true)
        } catch {
            // Never switched: the CLI stays in `previous` (with at most some extra ask rules, which only ask more).
            if var record = store[id], record.permissionMode == .plan {
                record.permissionMode = previous
                store[id] = record
                save()
                emit(.sessionUpdated(record.engineSession))
            }
            throw ClaudeCodeError.planGuardFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        do {
            _ = try await control(id, ["subtype": "set_permission_mode", "mode": .string(ClaudePermissionModes.cliMode(.plan))])
            return
        } catch {
            reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if var record = store[id], record.permissionMode == .plan {
            record.permissionMode = previous
            store[id] = record
            save()
            emit(.sessionUpdated(record.engineSession))
        }
        if let session = live[id] {
            if session.turnsInFlight > 0 { try? await interrupt(id) }
            do {
                _ = try await control(id, ["subtype": "set_permission_mode", "mode": .string(ClaudePermissionModes.cliMode(previous))],
                                      timeout: .seconds(10))
            } catch {
                // The CLI may still be in plan without the guard: end the process; the next prompt starts a new one.
                stopProcess(id)
            }
        }
        throw ClaudeCodeError.planGuardFailed(reason ?? "no answer")
    }

    /// Adds or removes the plan guard's ask rules on the running process and waits for the CLI to accept them
    /// (`ClaudePlanGuard`). Throws when the CLI refuses or does not answer.
    private func applyPlanGuard(_ root: String, planOn: Bool) async throws {
        guard let session = live[root] else { throw ClaudeCodeError.processFailed("the agent is not running") }
        let generation = session.process.generation
        _ = try await control(root, ["subtype": "apply_flag_settings",
                                     "settings": ClaudePlanGuard.settings(planOn: planOn, base: session.basePermissions)])
        guard live[root]?.process.generation == generation else { throw ClaudeCodeError.processFailed("the agent restarted") }
        live[root]?.planGuardOn = planOn
    }

    /// Before a turn of a plan session: the guard must be confirmed on this process, or the turn is not sent. A process
    /// that cannot take it is stopped, so the next try starts clean.
    private func ensurePlanGuard(_ root: String) async throws {
        guard store[root]?.permissionMode == .plan, let session = live[root], !session.planGuardOn else { return }
        do {
            try await applyPlanGuard(root, planOn: true)
        } catch {
            if live[root]?.process.generation == session.process.generation { stopProcess(root) }
            throw ClaudeCodeError.planGuardFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func switchModel(_ id: String, model: ModelRef) async throws {
        var record = try rootRecord(id, action: "change model")
        guard ClaudeModels.isClaudeProvider(model.providerID) else {
            throw ClaudeCodeError.invalidArgument("\(model) is not a Claude model.")
        }
        let billingChanged = record.billing != ClaudeModels.billing(for: model)
        let oldEffort = record.effort
        record.model = model
        if let variant = model.variant, ClaudeModels.effortLevels.contains(variant) { record.effort = variant }
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        guard live[id] != nil else { return }
        if billingChanged {
            restartWhenIdle(id)
            return
        }
        do {
            _ = try await control(id, ["subtype": "set_model", "model": .string(model.id)])
            if record.effort != oldEffort {
                _ = try await control(id, ["subtype": "apply_flag_settings",
                                           "settings": ["effortLevel": record.effort.map(JSONValue.string) ?? .null]])
            }
        } catch {
            restartWhenIdle(id)
        }
    }

    func children(of id: String) -> [EngineSession] {
        let root = ClaudeSessionIDs.root(of: id)
        var result: [String: EngineSession] = [:]
        if let record = store[root], let file = files.sessionFile(record.cliID, hint: record.transcriptPath.map(URL.init(fileURLWithPath:))) {
            let subagents = files.subagents(sessionFile: file)
            var parents: [String: String] = [:]
            for subagent in subagents {
                let inner = ClaudeTranscriptBuilder.agentToolIDs(in: ClaudeTranscriptFiles.read(subagent.file).entries)
                for tool in inner { parents[tool] = ClaudeSessionIDs.child(root: root, toolUseID: subagent.toolUseID) }
            }
            for subagent in subagents {
                let childID = ClaudeSessionIDs.child(root: root, toolUseID: subagent.toolUseID)
                result[childID] = EngineSession(id: childID, parentID: parents[subagent.toolUseID] ?? root, title: subagent.description,
                                                directory: record.directory, agent: subagent.agentType,
                                                created: subagent.created, updated: subagent.updated)
            }
        }
        for (childID, child) in children where ClaudeSessionIDs.root(of: childID) == root {
            if let known = result[childID] {
                result[childID]?.title = child.title.isEmpty ? known.title : child.title
                result[childID]?.archived = child.archived
            } else {
                result[childID] = child
            }
        }
        return result.values.filter { $0.parentID == id }.sorted { $0.created < $1.created }
    }

    // MARK: Transcripts

    func transcriptSource(_ id: String) throws -> TranscriptSource {
        let root = ClaudeSessionIDs.root(of: id)
        var record = try record(root)
        let running = (live[root]?.turnsInFlight ?? 0) > 0
        var builder = ClaudeTranscriptBuilder(rootID: root, directory: record.directory, syntheticTexts: Set(record.syntheticTexts),
                                              finished: !running)
        let hint = record.transcriptPath.map(URL.init(fileURLWithPath:))
        if let toolUseID = ClaudeSessionIDs.toolUseID(of: id) {
            builder.includeSidechains = true
            guard let rootFile = files.sessionFile(record.cliID, hint: hint),
                  let subagent = files.subagents(sessionFile: rootFile).first(where: { $0.toolUseID == toolUseID }) else {
                return TranscriptSource(file: nil, leafOverride: nil, builder: builder)
            }
            return TranscriptSource(file: subagent.file, leafOverride: nil, builder: builder)
        }
        if record.started, let file = files.sessionFile(record.cliID, hint: hint) {
            if record.transcriptPath != file.path {
                record.transcriptPath = file.path
                store[root] = record
                save()
            }
            return TranscriptSource(file: file, leafOverride: record.resumeAt, builder: builder)
        }
        if let from = record.forkFrom, let file = files.sessionFile(from) {
            return TranscriptSource(file: file, leafOverride: record.resumeAt, builder: builder)
        }
        return TranscriptSource(file: nil, leafOverride: nil, builder: builder)
    }

    func changedFileSources(_ id: String) throws -> [FileSource] {
        let root = ClaudeSessionIDs.root(of: id)
        let source = try transcriptSource(root)
        guard let file = source.file else { return [] }
        var result = [FileSource(file: file, leafOverride: source.leafOverride, builder: source.builder)]
        var subBuilder = source.builder
        subBuilder.includeSidechains = true
        for subagent in files.subagents(sessionFile: file) {
            result.append(FileSource(file: subagent.file, leafOverride: nil, builder: subBuilder))
        }
        return result
    }

    // MARK: Processes

    private func ensureProcess(_ id: String) throws {
        let record = try record(id)
        let trusted = configuration.trust.isTrusted(record.directory)
        if let session = live[id], session.process.isRunning {
            if session.turnsInFlight > 0 { return }
            // A trust change takes effect once the process is idle: the next prompt starts a new one. So does a change
            // to project files the process reads that now needs confirming (checked again below, which throws).
            var current = session.trusted == trusted
            if current, session.readsProjectFiles { current = projectFilesProblem(record) == nil }
            if current { return }
            stopProcess(id)
        }
        live[id] = nil
        guard let exe = executableURL() else { throw ClaudeCodeError.notInstalled }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ClaudeCodeError.invalidArgument("The project folder does not exist: \(record.directory)")
        }
        // What the project's own settings may do (see `ClaudeSettingsPlan`); throws when the user must trust or confirm.
        let plan = try settingsPlan(directory: record.directory, billing: record.billing, trusted: trusted)
        var apiKey: String?
        if record.billing == .apiKey {
            guard let key = keychain.read() else {
                throw ClaudeCodeError.invalidArgument("No Anthropic API key is saved for Claude API billing. Add one in Settings.")
            }
            apiKey = key
        }
        let start: ClaudeLaunchOptions.Start
        if let from = record.forkFrom, !record.started {
            start = .fork(from: from)
        } else {
            start = record.started ? .resume : .new
        }
        let model = record.model.map(\.id).flatMap { $0 == "default" ? nil : $0 }
        let env = ClaudeCLI.environment(base: configuration.baseEnvironment, billing: record.billing, apiKey: apiKey,
                                        fileCheckpointing: configuration.fileCheckpointing)
        // A snapshot plan hands the CLI a private copy of the confirmed settings; it never reads the project's files.
        // A project plan pins the redirect-capable keys with a command-line settings file, which outranks the project's.
        var snapshotArguments: [String] = []
        var snapshotFolder: URL?
        var basePermissions: JSONValue?
        switch plan {
        case .snapshot(let snapshot):
            basePermissions = ClaudePlanGuard.basePermissions(snapshot.settings)
            let written = try Self.writeSnapshot(snapshot)
            snapshotFolder = written.folder
            snapshotArguments = written.arguments
        case .project:
            let pins = ClaudeProjectSettings.loginPins(environment: env,
                                                       userSettings: ClaudeProjectSettings.userSettingsFile(environment: env))
            let written = try Self.writePrivateFiles([("settings.json", JSONValue.object(["env": .object(pins)]).lineData, "--settings")])
            snapshotFolder = written.folder
            snapshotArguments = written.arguments
        case .userOnly:
            break
        }
        let options = ClaudeLaunchOptions(sessionID: record.cliID, start: start, resumeAt: start == .new ? nil : record.resumeAt,
                                          model: model, effort: record.effort, permissionMode: record.permissionMode,
                                          settingSources: configuration.settingSources.effective(trusted: plan == .project),
                                          thinkingDisplay: configuration.thinkingDisplay,
                                          fastMode: record.fastMode, extraArguments: configuration.extraArguments + snapshotArguments)
        generation += 1
        let process: ClaudeProcess
        do {
            process = try ClaudeProcess.launch(executable: exe, arguments: ClaudeCLI.arguments(options), environment: env,
                                               directory: URL(fileURLWithPath: record.directory), generation: generation)
        } catch {
            if let snapshotFolder { try? FileManager.default.removeItem(at: snapshotFolder) }
            throw error
        }
        var decoder = ClaudeStreamDecoder(rootID: id, directory: record.directory, usage: record.usage)
        decoder.contextWindows = contextWindows
        decoder.lastContextTokens = record.lastContextTokens
        decoder.reportsCost = record.billing == .apiKey
        live[id] = Live(process: process, decoder: decoder, bypassAllowed: record.permissionMode == .bypass,
                        launchedWithResumeAt: options.resumeAt != nil, trusted: trusted, readsProjectFiles: plan == .project,
                        basePermissions: basePermissions)
        // A plan session gets the plan guard before its first turn (`ensurePlanGuard`, called by `send`).
        let gen = generation
        let lines = process.lines
        Task {
            for await line in lines { self.handle(line: line, root: id, generation: gen) }
            let status = await process.waitForExit()
            if let snapshotFolder { try? FileManager.default.removeItem(at: snapshotFolder) }
            self.processExited(root: id, generation: gen, status: status)
        }
        if plan == .project {
            Task {
                repeat {
                    try? await Task.sleep(for: .seconds(1))
                } while self.watchProjectSettings(root: id, generation: gen)
            }
        }
        // The CLI's initialize answer lists models, commands and fast mode; the account part is never read.
        let directory = record.directory
        Task {
            if let response = try? await self.control(id, ["subtype": "initialize"], timeout: .seconds(30)) {
                self.storeInitialize(ClaudeInitializeInfo(response: response), directory: directory)
            }
        }
    }

    /// Writes a snapshot's `--settings` and `--mcp-config` files into a new folder only the user can read.
    static func writeSnapshot(_ snapshot: ClaudeProjectSettings.Snapshot) throws -> (folder: URL, arguments: [String]) {
        var files: [(name: String, data: Data, flag: String)] = [("settings.json", snapshot.settingsData, "--settings")]
        if let mcp = snapshot.mcpData { files.append(("mcp.json", mcp, "--mcp-config")) }
        return try writePrivateFiles(files)
    }

    /// Writes files into a new folder only the user can read and returns the flags that pass them to the CLI.
    static func writePrivateFiles(_ files: [(name: String, data: Data, flag: String)]) throws -> (folder: URL, arguments: [String]) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ensemble-claude-settings-\(UUID().uuidString.lowercased())")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var arguments: [String] = []
            for file in files {
                let url = folder.appendingPathComponent(file.name)
                guard fm.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                    throw ClaudeCodeError.processFailed("could not write the agent's settings file")
                }
                arguments += [file.flag, url.path]
            }
            return (folder, arguments)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    private func storeInitialize(_ info: ClaudeInitializeInfo, directory: String) {
        if !info.models.isEmpty { initializeInfo = info }
        commandCache[directory] = (Date(), info)
    }

    private func restartWhenIdle(_ id: String) {
        guard let session = live[id] else { return }
        if session.turnsInFlight == 0 {
            stopProcess(id)
        } else {
            live[id]?.restartWhenIdle = true
        }
    }

    /// Ends a session's process now. The next prompt starts a new one with `--resume`.
    private func stopProcess(_ id: String) {
        guard let session = live.removeValue(forKey: id) else { return }
        session.process.terminate()
        failWaiters(root: id, message: "the agent process stopped")
        clearPending(root: id)
        if session.turnsInFlight > 0 {
            emit(.executionEnded(sessionID: id, outcome: "interrupted", error: nil))
            emit(.activity(sessionID: id, .idle))
        }
    }

    func shutdown() {
        for id in Array(live.keys) { stopProcess(id) }
    }

    private func failWaiters(root: String, message: String) {
        for (requestID, waiter) in waiters where waiter.root == root {
            waiters[requestID] = nil
            waiter.continuation.resume(throwing: ClaudeCodeError.controlFailed(message))
        }
    }

    private func clearPending(root: String) {
        for (requestID, prompt) in pending where prompt.sessionID == root {
            pending[requestID] = nil
            emit(.permissionReplied(sessionID: root, requestID: requestID))
        }
    }

    private func processExited(root: String, generation: Int, status: Int32) {
        guard let session = live[root], session.process.generation == generation else { return }
        live[root] = nil
        failWaiters(root: root, message: "the agent process exited")
        clearPending(root: root)
        let stderr = session.process.stderrText
        if stderr.contains("No conversation found"), var record = store[root] {
            record.started = false
            store[root] = record
            save()
        }
        guard session.turnsInFlight > 0 else { return }
        if session.interrupting {
            emit(.executionEnded(sessionID: root, outcome: "interrupted", error: nil))
            emit(.activity(sessionID: root, .idle))
        } else {
            let tail = stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
            let message = tail.isEmpty ? "claude exited with status \(status)" : String(tail.prefix(500))
            emit(.executionEnded(sessionID: root, outcome: "failed", error: ClaudeStreamDecoder.friendlyError(message)))
            emit(.activity(sessionID: root, .failed))
        }
    }

    private func write(_ root: String, _ json: JSONValue) throws {
        guard let session = live[root] else { throw ClaudeCodeError.processFailed("the agent is not running") }
        try session.process.write(json.lineData)
    }

    /// Sends a control request and waits for its answer.
    private func control(_ root: String, _ request: JSONValue, timeout: Duration = .seconds(15)) async throws -> JSONValue {
        guard live[root] != nil else { throw ClaudeCodeError.controlFailed("the agent is not running") }
        let requestID = "ensemble-" + UUID().uuidString.lowercased()
        let line: JSONValue = ["type": "control_request", "request_id": .string(requestID), "request": request]
        return try await withCheckedThrowingContinuation { continuation in
            waiters[requestID] = (root, continuation)
            do {
                try write(root, line)
            } catch {
                waiters[requestID] = nil
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.timeOut(requestID)
            }
        }
    }

    private func timeOut(_ requestID: String) {
        guard let waiter = waiters.removeValue(forKey: requestID) else { return }
        waiter.continuation.resume(throwing: ClaudeCodeError.controlFailed("no answer in time"))
    }

    // MARK: Reading the stream

    private func handle(line: String, root: String, generation: Int) {
        guard var session = live[root], session.process.generation == generation else { return }
        let outputs = session.decoder.decode(line: line)
        live[root] = session
        for output in outputs { apply(output, root: root) }
    }

    private func apply(_ output: ClaudeStreamDecoder.Output, root: String) {
        switch output {
        case .event(let event):
            if case .sessionCreated(let child) = event, ClaudeSessionIDs.isChild(child.id) { children[child.id] = child }
            emit(event)

        case .permission(let prompt):
            let inPlan = store[root]?.permissionMode == .plan
            if inPlan, !prompt.isInteraction {
                // Layer 2 of the plan guard: Ensemble's own decision, whatever the CLI suggests.
                switch ClaudePlanGuard.decision(toolName: prompt.toolName, input: prompt.input, plansFolder: plansFolder) {
                case .refuse:
                    try? write(root, prompt.planEditRefusal())
                    return
                case .allowPlanFile:
                    try? write(root, prompt.response(decision: .once, message: nil))
                    return
                case .ask:
                    break
                }
            }
            // Plans and questions always wait for the user; in plan mode remembered rules approve nothing.
            if !prompt.isInteraction, !inPlan, rules[root]?.allows(prompt) == true {
                try? write(root, prompt.response(decision: .once, message: nil))
                return
            }
            pending[prompt.requestID] = prompt
            emit(.permissionAsked(prompt.request))
            emit(.activity(sessionID: root, .waitingForPermission))

        case .unsupportedControl(let requestID, let subtype):
            try? write(root, ["type": "control_response",
                              "response": ["subtype": "error", "request_id": .string(requestID),
                                           "error": .string("Ensemble does not handle \(subtype)")]])

        case .controlResponse(let requestID, let success, let payload):
            guard let waiter = waiters.removeValue(forKey: requestID) else { return }
            if success {
                waiter.continuation.resume(returning: payload)
            } else {
                waiter.continuation.resume(throwing: ClaudeCodeError.controlFailed(payload.stringValue ?? "error"))
            }

        case .controlCancel(let requestID):
            if pending.removeValue(forKey: requestID) != nil {
                emit(.permissionReplied(sessionID: root, requestID: requestID))
            }

        case .initialized(let info):
            guard var record = store[root] else { return }
            record.started = true
            if let cliID = info.cliSessionID, !cliID.isEmpty {
                if record.forkFrom != nil { record.forkFrom = nil }
                if cliID != record.cliID { record.cliSessionID = cliID }
            }
            store[root] = record
            save()
            if info.connectors != connectors {
                connectors = info.connectors
                emit(.connectorsChanged)
            }
            if !info.skills.isEmpty { skillsByDirectory[record.directory] = Set(info.skills) }
            if !info.terminalCommands.isEmpty { terminalCommands = Set(info.terminalCommands) }

        case .turnEnded(let summary):
            guard var session = live[root] else { return }
            session.turnsInFlight = max(summary.queuedTurns, session.turnsInFlight - 1, 0)
            session.interrupting = false
            let resumeAtDone = session.launchedWithResumeAt
            session.launchedWithResumeAt = false
            live[root] = session
            contextWindows.merge(session.decoder.contextWindows) { _, new in new }
            if var record = store[root] {
                record.usage = session.decoder.usage
                record.lastContextTokens = session.decoder.lastContextTokens ?? record.lastContextTokens
                if resumeAtDone { record.resumeAt = nil }
                record.updated = Date()
                store[root] = record
                save()
            }
            if summary.outcome == "interrupted" { clearPending(root: root) }
            if session.restartWhenIdle, session.turnsInFlight == 0 { stopProcess(root) }

        case .rateLimit(let limits):
            planLimits = limits
        }
    }

    // MARK: Talking

    /// Where the CLI keeps plan files for this engine's processes.
    private var plansFolder: String? { ClaudePlanGuard.plansFolder(environment: configuration.baseEnvironment) }

    func send(_ id: String, text: String, files attachments: [URL], synthetic: Bool) async throws {
        var record = try rootRecord(id, action: "be messaged directly")
        // The conversation moves on: the last rewind can no longer be undone.
        clearRewindUndo(id)
        let queued = record.queuedSynthetic
        let blocks = try ClaudeCLI.contentBlocks(synthetic: queued, text: text, files: attachments)
        for text in queued { record.rememberSynthetic(text) }
        if synthetic { record.rememberSynthetic(text) }
        var renamed = false
        if record.title.isEmpty, !synthetic, !text.hasPrefix("/"), !text.isEmpty {
            record.title = Self.title(from: text)
            renamed = true
        }
        record.queuedSynthetic = []
        record.updated = Date()
        store[id] = record
        do {
            try ensureProcess(id)
            // Plan mode fails closed: no turn is sent until the CLI has confirmed the guard.
            try await ensurePlanGuard(id)
            try write(id, ClaudeCLI.userMessage(blocks: blocks))
        } catch {
            if var restored = store[id] {
                restored.queuedSynthetic = queued
                store[id] = restored
            }
            save()
            throw error
        }
        live[id]?.turnsInFlight += 1
        save()
        if renamed { emit(.sessionUpdated(record.engineSession)) }
        emit(.activity(sessionID: id, .working))
    }

    /// Adds a message to the running turn without stopping it (priority `next`: the CLI folds it in after the tool
    /// calls in flight). With no turn running it is an ordinary `send`. A folded message gets no `result` of its own,
    /// and one the CLI runs as its own turn afterwards is counted in the running turn's `queued_turn_count`, which
    /// `.turnEnded` already uses, so `turnsInFlight` is not raised here.
    func steer(_ id: String, text: String, files attachments: [URL]) async throws {
        guard let session = live[id], session.turnsInFlight > 0, !session.interrupting else {
            try await send(id, text: text, files: attachments, synthetic: false)
            return
        }
        var record = try rootRecord(id, action: "be messaged directly")
        if record.permissionMode == .plan, !session.planGuardOn {
            throw ClaudeCodeError.planGuardFailed("the read-only rules are not in place")
        }
        let blocks = try ClaudeCLI.contentBlocks(synthetic: [], text: text, files: attachments)
        try write(id, ClaudeCLI.userMessage(blocks: blocks, priority: "next"))
        record.updated = Date()
        store[id] = record
        save()
        emit(.activity(sessionID: id, .working))
    }

    func queueSynthetic(_ id: String, text: String) throws {
        var record = try rootRecord(id, action: "be messaged directly")
        record.queuedSynthetic.append(text)
        store[id] = record
        save()
    }

    func interrupt(_ id: String) async throws {
        let root = ClaudeSessionIDs.root(of: id)
        guard let session = live[root], session.turnsInFlight > 0 else { return }
        live[root]?.decoder.interruptRequested = true
        live[root]?.interrupting = true
        do {
            _ = try await control(root, ["subtype": "interrupt"], timeout: .seconds(10))
        } catch {
            // The CLI did not take the interrupt: end the process; the session resumes on the next prompt.
            if let current = live[root], current.process.generation == session.process.generation {
                current.process.terminate()
            }
        }
    }

    func replyPermission(requestID: String, decision: PermissionDecision, message: String?) throws {
        if let prompt = pending[requestID], prompt.isInteraction {
            // Plans and questions are answered with their own calls; Reject declines or keeps planning.
            guard decision == .reject else {
                throw ClaudeCodeError.invalidArgument(prompt.isPlan ? "Choose Proceed on the plan card." : "Answer the question in its card.")
            }
            pending[requestID] = nil
            let root = prompt.sessionID
            try write(root, prompt.isPlan ? prompt.planResponse(.keepPlanning(comments: [])) : prompt.questionResponse(answers: []))
            emit(.permissionReplied(sessionID: root, requestID: requestID))
            return
        }
        guard let prompt = pending.removeValue(forKey: requestID) else {
            throw ClaudeCodeError.invalidArgument("This permission prompt is no longer open.")
        }
        let root = prompt.sessionID
        if decision == .always {
            var sessionRules = rules[root] ?? ClaudePermissionRules()
            sessionRules.add(prompt.alwaysRules)
            rules[root] = sessionRules
        }
        guard live[root] != nil else {
            emit(.permissionReplied(sessionID: root, requestID: requestID))
            throw ClaudeCodeError.processFailed("the agent stopped before the answer arrived")
        }
        try write(root, prompt.response(decision: decision, message: message))
        emit(.permissionReplied(sessionID: root, requestID: requestID))
        if decision == .always, let sessionRules = rules[root] {
            for (otherID, other) in pending where other.sessionID == root && sessionRules.allows(other) {
                pending[otherID] = nil
                try? write(root, other.response(decision: .once, message: nil))
                emit(.permissionReplied(sessionID: root, requestID: otherID))
            }
        }
        if !pending.values.contains(where: { $0.sessionID == root }), (live[root]?.turnsInFlight ?? 0) > 0 {
            emit(.activity(sessionID: root, .working))
        }
    }

    // MARK: Plans and questions

    /// The open plan or question `requestID`, only when it belongs to `sessionID` (the root session that asked).
    private func interactionPrompt(_ requestID: String, sessionID: String) throws -> ClaudePermissionPrompt {
        guard let prompt = pending[requestID], prompt.isInteraction,
              prompt.sessionID == ClaudeSessionIDs.root(of: sessionID) else {
            throw ClaudeCodeError.invalidArgument("This question or plan is no longer open in this session.")
        }
        return prompt
    }

    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) throws {
        let prompt = try interactionPrompt(requestID, sessionID: sessionID)
        guard prompt.isQuestion else { throw ClaudeCodeError.invalidArgument("This request is not a question.") }
        let root = prompt.sessionID
        guard live[root] != nil else {
            pending[requestID] = nil
            emit(.permissionReplied(sessionID: root, requestID: requestID))
            throw ClaudeCodeError.processFailed("the agent stopped before the answer arrived")
        }
        pending[requestID] = nil
        try write(root, prompt.questionResponse(answers: answers))
        emit(.permissionReplied(sessionID: root, requestID: requestID))
        if !pending.values.contains(where: { $0.sessionID == root }), (live[root]?.turnsInFlight ?? 0) > 0 {
            emit(.activity(sessionID: root, .working))
        }
    }

    /// Proceed switches the CLI to the chosen mode (and lifts the plan guard) before the plan is approved, so the
    /// agent's next tool call already runs under the new mode. Keep planning denies `ExitPlanMode` with the comments.
    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws {
        let prompt = try interactionPrompt(requestID, sessionID: sessionID)
        guard prompt.isPlan else { throw ClaudeCodeError.invalidArgument("This request is not a plan.") }
        let root = prompt.sessionID
        guard let session = live[root] else {
            pending[requestID] = nil
            emit(.permissionReplied(sessionID: root, requestID: requestID))
            throw ClaudeCodeError.processFailed("the agent stopped before the answer arrived")
        }
        if case .proceed(let mode) = decision {
            guard mode != .plan else { throw ClaudeCodeError.invalidArgument("Proceed needs a mode other than Plan.") }
            guard mode != .bypass || session.bypassAllowed else {
                throw ClaudeCodeError.invalidArgument("Bypass needs the agent restarted. Choose another mode, then switch to Bypass.")
            }
            // Claimed before waiting, so a second answer or a cancel cannot use the prompt meanwhile.
            pending[requestID] = nil
            do {
                _ = try await control(root, ["subtype": "set_permission_mode", "mode": .string(ClaudePermissionModes.cliMode(mode))])
            } catch {
                if live[root] != nil { pending[requestID] = prompt }
                throw error
            }
            // Lifting the guard can fail safely: its ask rules stay (the agent asks more) until the process restarts.
            do { try await applyPlanGuard(root, planOn: false) } catch { restartWhenIdle(root) }
            if var record = store[root] {
                record.permissionMode = mode
                store[root] = record
                save()
                emit(.sessionUpdated(record.engineSession))
            }
        } else {
            pending[requestID] = nil
        }
        try write(root, prompt.planResponse(decision))
        emit(.permissionReplied(sessionID: root, requestID: requestID))
        if !pending.values.contains(where: { $0.sessionID == root }), (live[root]?.turnsInFlight ?? 0) > 0 {
            emit(.activity(sessionID: root, .working))
        }
    }

    func planModeSupport(sessionID: String) -> PlanModeSupport {
        ClaudeSessionIDs.isChild(sessionID)
            ? .unsupported(reason: "A subagent follows the mode of the session that started it.")
            : .supported
    }

    func pendingRequests() -> [PermissionRequest] {
        pending.values.map(\.request).sorted { $0.created < $1.created }
    }

    // MARK: Panels

    func context(_ id: String) async throws -> ContextBreakdown {
        let root = ClaudeSessionIDs.root(of: id)
        let record = try record(root)
        if live[root] != nil, let response = try? await control(root, ["subtype": "get_context_usage"], timeout: .seconds(10)),
           let breakdown = ClaudeContext.breakdown(from: response) {
            return breakdown
        }
        let modelID = record.model?.id ?? "opus"
        return ClaudeContext.estimate(usedTokens: record.lastContextTokens,
                                      limit: ClaudeModels.contextLimit(for: modelID, observed: contextWindows))
    }

    // MARK: Models

    /// The CLI's `initialize` answer from a short process that sends no prompt (no tokens used).
    /// `--no-session-persistence` keeps it out of the transcripts. The model list is read with no settings files (so
    /// the user's hooks do not fire); the command list uses the configured sources, since it depends on them.
    private func probeInitialize(directory: String?, settingSources: ClaudeSettingSources) async -> ClaudeInitializeInfo? {
        guard let exe = executableURL() else { return nil }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "default", "--no-session-persistence"]
        if let sources = settingSources.argument { args += ["--setting-sources", sources] }
        let env = ClaudeCLI.environment(base: configuration.baseEnvironment, billing: .subscription, apiKey: nil)
        let folder = directory.map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        guard let process = try? ClaudeProcess.launch(executable: exe, arguments: args, environment: env, directory: folder, generation: -1) else {
            return nil
        }
        let requestID = "ensemble-init-" + UUID().uuidString.lowercased()
        let request: JSONValue = ["type": "control_request", "request_id": .string(requestID), "request": ["subtype": "initialize"]]
        guard (try? process.write(request.lineData)) != nil else {
            process.terminate()
            return nil
        }
        let lines = process.lines
        let reader = Task { () -> ClaudeInitializeInfo? in
            for await line in lines {
                guard line.contains(requestID), let json = JSONValue.parse(line: line),
                      json["type"]?.stringValue == "control_response",
                      json["response"]?["request_id"]?.stringValue == requestID,
                      json["response"]?["subtype"]?.stringValue == "success",
                      let payload = json["response"]?["response"] else { continue }
                return ClaudeInitializeInfo(response: payload)
            }
            return nil
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(25))
            process.terminate()
        }
        let info = await reader.value
        timer.cancel()
        process.terminate()
        return info
    }

    private func modelCatalog() async -> ClaudeInitializeInfo? {
        if let initializeInfo { return initializeInfo }
        if let info = await probeInitialize(directory: nil, settingSources: .none), !info.models.isEmpty {
            initializeInfo = info
            return info
        }
        return nil
    }

    func models() async -> [ModelInfo] {
        let auth = await authState(refresh: false)
        let info = await modelCatalog()
        var entries: [(id: String, name: String, levels: [String])] = []
        if let info {
            for model in info.models {
                let name = model.value == "default" ? "Default (\(model.resolvedModel ?? "your setting"))" : model.displayName
                entries.append((model.value, name, model.effortLevels))
            }
            for extra in ClaudeModels.catalog where extra.id.hasSuffix("[1m]") && !entries.contains(where: { $0.id == extra.id }) {
                entries.append((extra.id, extra.name, ClaudeModels.effortLevels))
            }
        } else {
            entries = ClaudeModels.catalog.map { ($0.id, $0.name, ClaudeModels.effortLevels) }
        }
        func infos(provider: String, providerName: String, available: Bool) -> [ModelInfo] {
            entries.map { entry in
                let resolved = info?.models.first(where: { $0.value == entry.id })?.resolvedModel ?? entry.id
                let limit = ClaudeModels.contextLimit(for: entry.id, observed: contextWindows)
                    ?? ClaudeModels.contextLimit(for: resolved, observed: contextWindows)
                return ModelInfo(ref: ModelRef(providerID: provider, id: entry.id), name: entry.name, providerName: providerName,
                                 contextLimit: limit, variants: entry.levels, available: available)
            }
        }
        var result = infos(provider: ClaudeModels.subscriptionProviderID, providerName: ClaudeModels.subscriptionProviderName,
                           available: auth.installed && auth.loggedIn)
        if auth.installed, keychain.hasKey {
            result += infos(provider: ClaudeModels.apiKeyProviderID, providerName: ClaudeModels.apiKeyProviderName, available: true)
        }
        return result
    }

    func providers() async -> [ProviderInfo] {
        let auth = await authState(refresh: false)
        return [
            ProviderInfo(id: ClaudeModels.subscriptionProviderID, name: ClaudeModels.subscriptionProviderName,
                         connected: auth.installed && auth.loggedIn),
            ProviderInfo(id: ClaudeModels.apiKeyProviderID, name: ClaudeModels.apiKeyProviderName,
                         connected: auth.installed && keychain.hasKey),
        ]
    }

    // MARK: Effort and fast mode

    func modelOptions(for model: ModelRef) async -> ModelOptions {
        let info = await modelCatalog()
        let base = model.id.hasSuffix("[1m]") ? String(model.id.dropLast(4)) : model.id
        if let entry = info?.models.first(where: { $0.value == base || $0.resolvedModel == base }) {
            return ModelOptions(effortLevels: entry.effortLevels.compactMap(EffortLevel.init(rawValue:)), defaultEffort: nil,
                                supportsFastMode: entry.supportsFastMode)
        }
        return ModelOptions(effortLevels: EffortLevel.allCases, defaultEffort: nil, supportsFastMode: base.contains("opus"))
    }

    func setEffort(_ id: String, effort: String?) async throws {
        var record = try rootRecord(id, action: "have its own effort")
        if let effort, !ClaudeModels.effortLevels.contains(effort) { throw ClaudeCodeError.invalidArgument("Unknown effort level \(effort).") }
        record.effort = effort
        if record.model != nil { record.model?.variant = effort }
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        guard live[id] != nil else { return }
        do {
            _ = try await control(id, ["subtype": "apply_flag_settings", "settings": ["effortLevel": effort.map(JSONValue.string) ?? .null]])
        } catch {
            restartWhenIdle(id)
        }
    }

    func setFastMode(_ id: String, enabled: Bool) async throws {
        var record = try rootRecord(id, action: "have its own fast mode")
        if enabled, let model = record.model {
            let options = await modelOptions(for: model)
            guard options.supportsFastMode else { throw ClaudeCodeError.notSupported("Fast mode is not available for \(model.id).") }
        }
        record.fastMode = enabled
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        guard live[id] != nil else { return }
        do {
            _ = try await control(id, ["subtype": "apply_flag_settings", "settings": ["fastMode": .bool(enabled)]])
        } catch {
            restartWhenIdle(id)
        }
    }

    // MARK: Fork and rewind

    func historySource(_ id: String) throws -> (file: URL, leafOverride: String?) {
        let record = try rootRecord(id, action: "be forked or rewound")
        if record.started, let file = files.sessionFile(record.cliID, hint: record.transcriptPath.map(URL.init(fileURLWithPath:))) {
            return (file, record.resumeAt)
        }
        if let from = record.forkFrom, let file = files.sessionFile(from) { return (file, record.resumeAt) }
        throw ClaudeCodeError.invalidArgument("This session has no messages yet.")
    }

    func createFork(of id: String, keep: String?) throws -> EngineSession {
        let source = try rootRecord(id, action: "be forked")
        let newID = UUID().uuidString.lowercased()
        let title = (source.title.isEmpty ? ClaudeSessionRecord.defaultTitle : source.title) + " (fork)"
        var fork = ClaudeSessionRecord(id: newID, title: title, directory: source.directory, model: source.model,
                                       permissionMode: source.permissionMode)
        fork.effort = source.effort
        fork.fastMode = source.fastMode
        fork.syntheticTexts = source.syntheticTexts
        if source.started {
            fork.forkFrom = source.cliID
        } else if let from = source.forkFrom {
            fork.forkFrom = from
        } else {
            throw ClaudeCodeError.invalidArgument("This session has no messages yet.")
        }
        fork.resumeAt = keep ?? source.resumeAt
        store[newID] = fork
        save()
        emit(.sessionCreated(fork.engineSession))
        return fork.engineSession
    }

    func applyRewind(_ id: String, cut: ClaudeHistory.Cut) async throws {
        var record = try rootRecord(id, action: "be rewound")
        guard (live[id]?.turnsInFlight ?? 0) == 0 else {
            throw ClaudeCodeError.invalidArgument("Stop the agent before rewinding.")
        }
        clearRewindUndo(id)
        // Files first, while a process can still read the session's checkpoints. Best effort: the conversation
        // rewinds even when files cannot be restored (for example a session started before checkpoints were on).
        if configuration.fileCheckpointing, record.started, let prompt = cut.restorePrompt {
            do {
                try ensureProcess(id)
                let check = try await control(id, ["subtype": "rewind_files", "user_message_id": .string(prompt), "dry_run": true])
                if check["canRewind"]?.boolValue == true {
                    _ = try await control(id, ["subtype": "rewind_files", "user_message_id": .string(prompt)], timeout: .seconds(60))
                    emit(.filesChanged(paths: (check["filesChanged"]?.arrayValue ?? []).compactMap(\.stringValue)))
                }
            } catch {}
        }
        stopProcess(id)
        record = try self.record(id)
        if let keep = cut.keep {
            record.resumeAt = keep
        } else {
            // Nothing kept: continue as a new CLI conversation.
            record.cliSessionID = UUID().uuidString.lowercased()
            record.started = false
            record.forkFrom = nil
            record.resumeAt = nil
            record.transcriptPath = nil
        }
        record.lastContextTokens = nil
        record.updated = Date()
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
    }

    // MARK: Rewind with choices

    /// The CLI's dry run of `rewind_files` for the prompt a cut restores to. Starts the session's process when needed
    /// (no turn runs). `canRewind` false comes with the reason in `error`.
    func fileRewindCheck(_ id: String, cut: ClaudeHistory.Cut) async throws -> ClaudeFileRewindCheck {
        let record = try rootRecord(id, action: "be rewound")
        guard configuration.fileCheckpointing else {
            return ClaudeFileRewindCheck(canRewind: false, files: [], error: ClaudeFileRewindCheck.checkpointsOff)
        }
        guard record.started, let prompt = cut.restorePrompt else {
            return ClaudeFileRewindCheck(canRewind: false, files: [], error: ClaudeFileRewindCheck.noSnapshot)
        }
        guard (live[id]?.turnsInFlight ?? 0) == 0 else {
            throw ClaudeCodeError.invalidArgument("Stop the agent before rewinding.")
        }
        try ensureProcess(id)
        let check = try await control(id, ["subtype": "rewind_files", "user_message_id": .string(prompt), "dry_run": true])
        let error = check["error"]?.stringValue
        return ClaudeFileRewindCheck(canRewind: check["canRewind"]?.boolValue == true,
                                     files: (check["filesChanged"]?.arrayValue ?? []).compactMap(\.stringValue),
                                     error: error?.isEmpty == false ? error : nil)
    }

    /// Rewinds to `cut`: files with the CLI's `rewind_files` (dry run first) for the code scopes, the conversation by
    /// resuming at the kept entry for the conversation scopes. Unlike `applyRewind`, a code scope fails rather than
    /// rewinding only the conversation. Keeps what Redo needs: the record from before, and a private copy of each file
    /// the CLI is about to put back. Returns the paths the CLI put back.
    func applyRewind(_ id: String, cut: ClaudeHistory.Cut, scope: RewindScope) async throws -> [String] {
        _ = try rootRecord(id, action: "be rewound")
        guard scope != .summarizeFromHere else { throw ClaudeCodeError.notSupported(ClaudeFileRewindCheck.noSummary) }
        guard (live[id]?.turnsInFlight ?? 0) == 0 else {
            throw ClaudeCodeError.invalidArgument("Stop the agent before rewinding.")
        }
        clearRewindUndo(id)
        var undo = ClaudeRewindUndo()
        var restored: [String] = []
        if scope.restoresFiles {
            let check = try await fileRewindCheck(id, cut: cut)
            guard check.canRewind, let prompt = cut.restorePrompt else {
                throw ClaudeCodeError.notSupported(check.error ?? ClaudeFileRewindCheck.noSnapshot)
            }
            if !check.files.isEmpty {
                let directory = try record(id).directory
                undo.files = try ClaudeRewindUndo.FileCopy.save(check.files.map { ClaudeRewindUndo.absolute($0, directory: directory) })
                _ = try await control(id, ["subtype": "rewind_files", "user_message_id": .string(prompt)], timeout: .seconds(60))
                restored = check.files
                emit(.filesChanged(paths: restored))
            }
        }
        if scope.removesMessages {
            stopProcess(id)
            var record = try self.record(id)
            undo.record = record
            if let keep = cut.keep {
                record.resumeAt = keep
            } else {
                record.cliSessionID = UUID().uuidString.lowercased()
                record.started = false
                record.forkFrom = nil
                record.resumeAt = nil
                record.transcriptPath = nil
            }
            record.lastContextTokens = nil
            record.updated = Date()
            store[id] = record
            save()
            emit(.sessionUpdated(record.engineSession))
        }
        if undo.record != nil || undo.files != nil { rewindUndo[id] = undo }
        return restored
    }

    /// True when the session's last rewind can still be undone.
    func canRedoRewind(_ id: String) -> Bool { rewindUndo[id] != nil }

    /// Undoes the session's last rewind: the conversation resumes where it was, and the files the CLI put back get
    /// the contents they had just before.
    func redoRewind(_ id: String) async throws {
        _ = try rootRecord(id, action: "be rewound")
        guard let undo = rewindUndo[id] else { throw ClaudeCodeError.invalidArgument("There is no rewind to undo in this session.") }
        guard (live[id]?.turnsInFlight ?? 0) == 0 else {
            throw ClaudeCodeError.invalidArgument("Stop the agent before undoing the rewind.")
        }
        rewindUndo[id] = nil
        defer { undo.files?.discard() }
        if let files = undo.files {
            try files.restore()
            emit(.filesChanged(paths: files.entries.map(\.path)))
        }
        if let before = undo.record {
            // Only where the conversation resumes goes back; title, mode, model and usage stay as they are now.
            stopProcess(id)
            var record = try record(id)
            record.cliSessionID = before.cliSessionID
            record.started = before.started
            record.forkFrom = before.forkFrom
            record.resumeAt = before.resumeAt
            record.transcriptPath = before.transcriptPath
            record.lastContextTokens = before.lastContextTokens
            record.updated = Date()
            store[id] = record
            save()
            emit(.sessionUpdated(record.engineSession))
        }
    }

    private func clearRewindUndo(_ id: String) {
        rewindUndo.removeValue(forKey: id)?.files?.discard()
    }

    // MARK: Commands

    func commands(directory: String?) async throws -> [EngineCommand] {
        let key = directory ?? ""
        let skills = skillsByDirectory[key] ?? []
        if let cached = commandCache[key], Date().timeIntervalSince(cached.date) < 600 {
            return cached.info.engineCommands(skills: skills, terminalOnly: terminalCommands)
        }
        guard executableURL() != nil else { throw ClaudeCodeError.notInstalled }
        // Never a project's own settings: the probe starts a process (hooks would run) before anyone is asked.
        guard let info = await probeInitialize(directory: directory, settingSources: configuration.settingSources.effective(trusted: false)) else {
            throw ClaudeCodeError.processFailed("could not read the command list")
        }
        commandCache[key] = (Date(), info)
        if initializeInfo == nil, !info.models.isEmpty { initializeInfo = info }
        return info.engineCommands(skills: skills, terminalOnly: terminalCommands)
    }
}

// MARK: Background tasks and plan limit stops

extension ClaudeEngineCore {
    /// Background shells and tasks of every running process (`ClaudeTaskTracker`).
    func backgroundTasks() -> [BackgroundTask] {
        live.values.flatMap { $0.decoder.tasks.running() }
    }

    /// The CLI's task id for a running subagent session.
    func subagentTaskID(_ childID: String) -> String? {
        live[ClaudeSessionIDs.root(of: childID)]?.decoder.tasks.taskID(forChild: childID)
    }

    /// Ends one task (a background shell, a workflow or a subagent) with the `stop_task` control request.
    func stopTask(_ taskID: String, root: String) async throws {
        guard live[root] != nil else { throw ClaudeCodeError.processFailed("the agent is not running") }
        _ = try await control(root, ["subtype": "stop_task", "task_id": .string(taskID)], timeout: .seconds(10))
    }

    /// The plan limit that ended the session's last turn.
    func usageLimitStop(_ sessionID: String) -> UsageLimitInfo? {
        live[ClaudeSessionIDs.root(of: sessionID)]?.decoder.lastLimitStop
    }
}
#endif
