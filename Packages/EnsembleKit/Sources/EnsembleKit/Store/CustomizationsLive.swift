import Foundation

/// What a running OpenCode server says about a folder: MCP server status, the skills it loaded and its plugins.
public struct CustomizationLiveData: Hashable, Sendable {
    public struct MCP: Hashable, Sendable {
        public var name: String
        public var state: ConnectorInfo.State
        public var message: String?
        public var integrationID: String?

        public init(name: String, state: ConnectorInfo.State, message: String? = nil, integrationID: String? = nil) {
            self.name = name
            self.state = state
            self.message = message
            self.integrationID = integrationID
        }
    }

    public struct Skill: Hashable, Sendable {
        public var id: String
        public var name: String?
        public var summary: String?
        /// A file path, or `skill://<name>/SKILL.md` for a built-in skill.
        public var path: String

        public init(id: String, name: String? = nil, summary: String? = nil, path: String) {
            self.id = id
            self.name = name
            self.summary = summary
            self.path = path
        }
    }

    public struct Plugin: Hashable, Sendable {
        public var id: String?
        /// An npm package name or a local file path.
        public var source: String
        public var isFile: Bool
        /// Why it failed to load, if it did.
        public var failure: String?

        public init(id: String? = nil, source: String, isFile: Bool, failure: String? = nil) {
            self.id = id
            self.source = source
            self.isFile = isFile
            self.failure = failure
        }
    }

    public var mcp: [MCP]
    /// Nil when the server did not answer the skill list.
    public var skills: [Skill]?
    /// Plugins other than OpenCode's built-in ones.
    public var plugins: [Plugin]

    public init(mcp: [MCP] = [], skills: [Skill]? = nil, plugins: [Plugin] = []) {
        self.mcp = mcp
        self.skills = skills
        self.plugins = plugins
    }
}

/// An engine that can report and act on its customizations for a folder (the OpenCode client).
public protocol CustomizationsLiveSource: Sendable {
    func customizationsLive(directory: String) async throws -> CustomizationLiveData
    /// Disconnects and connects the MCP server again.
    func restartMCPServer(_ name: String, directory: String) async throws
    /// Starts the browser sign-in for an MCP server that needs one (through its OpenCode integration).
    func startMCPSignIn(integrationID: String, directory: String) async throws -> OAuthAttempt
    func mcpSignInStatus(integrationID: String, attemptID: String, directory: String) async throws -> OAuthAttemptStatus
}

/// Picks the OpenCode server for a folder and merges its answers into a discovery report.
public enum CustomizationsLive {
    public struct Source: Sendable {
        public var engine: any CustomizationsLiveSource
        /// "your OpenCode service" or "Ensemble's private OpenCode server".
        public var serverName: String
    }

    /// The OpenCode server that serves new sessions in `folder` (`EngineRouter.registration(forNewSessionIn:model:)`):
    /// the shared service for trusted folders, Ensemble's private server otherwise. Nil when that is not an OpenCode
    /// client (for example the stand-in while the private server starts), and never the shared service for a folder
    /// that is not trusted, since asking it about the folder would load the folder's own config there.
    public static func source(for folder: String, router: EngineRouter) -> Source? {
        let registration = router.registration(forNewSessionIn: folder, model: nil)
        if registration.isFallback, !router.trust.isTrusted(folder) { return nil }
        guard let engine = registration.engine as? any CustomizationsLiveSource else { return nil }
        let isPrivate = registration.id == router.untrustedFolderRegistration?.id
        return Source(engine: engine, serverName: isPrivate ? "Ensemble's private OpenCode server" : "your OpenCode service")
    }

    /// The report with OpenCode's own answers: MCP status and sign-in integration, the skills it actually loaded
    /// (keeping project skills it skips for trust), and plugin load failures.
    public static func merge(_ report: CustomizationsReport, live: CustomizationLiveData, serverName: String,
                             environment: CustomizationsEnvironment = CustomizationsEnvironment()) -> CustomizationsReport {
        var result = report
        result.openCodeServer = serverName

        // MCP servers.
        // Each reported server goes to the config entry with its name: an active one first, else one turned off in its
        // config (OpenCode reports those as disabled). Entries skipped for trust are not on this server.
        var unmatched = live.mcp
        let candidates = result.mcpServers.indices.filter { result.mcpServers[$0].engine == .openCode }
        let ordered = candidates.filter { result.mcpServers[$0].status.isActive }
            + candidates.filter { if case .disabled = result.mcpServers[$0].status { return true } else { return false } }
        for index in ordered {
            guard let found = unmatched.firstIndex(where: { $0.name == result.mcpServers[index].name }) else { continue }
            let entry = unmatched.remove(at: found)
            result.mcpServers[index].live = CustomizationLiveStatus(state: entry.state, message: entry.message.map(CustomizationRedaction.text))
            result.mcpServers[index].integrationID = entry.integrationID
        }
        for entry in unmatched {
            result.mcpServers.append(CustomizationMCPServer(
                engine: .openCode, scope: .user, name: entry.name, transport: .unknown, target: "", sourcePath: nil,
                status: .loaded, live: CustomizationLiveStatus(state: entry.state, message: entry.message.map(CustomizationRedaction.text)),
                integrationID: entry.integrationID))
        }

        // Skills: OpenCode's list replaces the loaded ones; skipped project skills stay listed.
        if let skills = live.skills {
            let discovered = result.entries.filter { $0.engine == .openCode && $0.kind == .skill }
            let byPath = Dictionary(discovered.map { (WorkspaceTrust.resolvedPath($0.path) ?? $0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var merged: [CustomizationEntry] = []
            var loadedPaths = Set<String>()
            for skill in skills.sorted(by: { $0.id < $1.id }) {
                let key = skill.path.hasPrefix("/") ? (WorkspaceTrust.resolvedPath(skill.path) ?? skill.path) : skill.path
                loadedPaths.insert(key)
                if var known = byPath[key] {
                    known.status = .loaded
                    if let summary = skill.summary, known.summary.isEmpty { known.summary = CustomizationFiles.summary(summary) }
                    merged.append(known)
                    continue
                }
                let scope = scopeForOpenCodePath(skill.path, folder: report.folder, environment: environment)
                merged.append(CustomizationEntry(engine: .openCode, kind: .skill, name: skill.name ?? skill.id,
                                                 summary: CustomizationFiles.summary(skill.summary), path: skill.path,
                                                 scope: scope, status: .loaded))
            }
            for entry in discovered where !entry.status.isActive && !loadedPaths.contains(WorkspaceTrust.resolvedPath(entry.path) ?? entry.path) {
                merged.append(entry)
            }
            result.entries.removeAll { $0.engine == .openCode && $0.kind == .skill }
            result.entries += merged
        }

        // Plugins: mark failures, add plugins only the server knows about.
        for plugin in live.plugins {
            let match = result.hooks.firstIndex { hook in
                guard hook.engine == .openCode, hook.kind == .plugin else { return false }
                if plugin.isFile { return hook.sourcePath.map { WorkspaceTrust.resolvedPath($0) ?? $0 } == (WorkspaceTrust.resolvedPath(plugin.source) ?? plugin.source) }
                guard let name = hook.name else { return false }
                return name == plugin.source || name.hasPrefix(plugin.source + "@")
            }
            let status: CustomizationStatus = plugin.failure.map { .disabled("Failed to load: " + CustomizationRedaction.text($0)) } ?? .loaded
            if let match {
                if result.hooks[match].status.isActive { result.hooks[match].status = status }
            } else {
                result.hooks.append(CustomizationHook(engine: .openCode, kind: .plugin,
                                                      scope: scopeForOpenCodePath(plugin.source, folder: report.folder, environment: environment),
                                                      event: "Plugin", name: plugin.id ?? plugin.source,
                                                      handler: plugin.isFile ? "file" : "package",
                                                      command: CustomizationRedaction.text(plugin.source),
                                                      sourcePath: plugin.isFile ? plugin.source : nil, status: status))
            }
        }
        return result
    }

    /// Built in for `skill://` paths, project for paths in the folder or a folder above it (below the home folder),
    /// user otherwise.
    static func scopeForOpenCodePath(_ path: String, folder: String, environment: CustomizationsEnvironment) -> CustomizationScope {
        if path.hasPrefix("skill://") { return .builtIn }
        guard path.hasPrefix("/") else { return .user }
        let resolved = WorkspaceTrust.resolvedPath(path) ?? path
        let context = CustomizationsContext(folder: folder, trusted: true, environment: environment, scanNested: false)
        for level in context.openCodeLevels where resolved.hasPrefix(level + "/") {
            return .project
        }
        return .user
    }
}

// MARK: OpenCode client

private enum LiveWire {
    struct Skill: Decodable {
        let id: String
        let name: String?
        let description: String?
        let path: String
    }

    struct Plugin: Decodable {
        struct Source: Decodable {
            let type: String
            let target: String?
            let path: String?
        }

        struct State: Decodable {
            let status: String
            let error: String?
        }

        let id: String?
        let source: Source
        let state: State
    }
}

extension OpenCodeClient: CustomizationsLiveSource {
    /// `GET /api/mcp`, `/api/skill` and `/api/plugin` for the folder. A folder the server has not served yet answers
    /// while its config is still loading (checked: first no skills, or only some of the built-in ones, then the full
    /// list a quarter of a second later), so the lists are read until two answers in a row agree, at most five times.
    public func customizationsLive(directory: String) async throws -> CustomizationLiveData {
        var previous = try await liveOnce(directory: directory)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(350))
            let next = try await liveOnce(directory: directory)
            if next == previous, !(next.skills?.isEmpty ?? true) { return next }
            previous = next
        }
        return previous
    }

    private func liveOnce(directory: String) async throws -> CustomizationLiveData {
        let location = Self.location(directory)
        async let mcpList: Wire.LocationEnvelope<[Wire.Lossy<Wire.McpServer>]> = get("/api/mcp", query: location)
        async let skillList: Wire.LocationEnvelope<[Wire.Lossy<LiveWire.Skill>]> = get("/api/skill", query: location)
        async let pluginList: Wire.LocationEnvelope<[Wire.Lossy<LiveWire.Plugin>]> = get("/api/plugin", query: location)
        let mcp = try await mcpList.data.compactMap(\.value).sorted { $0.name < $1.name }.map { server in
            CustomizationLiveData.MCP(name: server.name, state: ConnectorInfo(wire: server).state, message: server.status.error,
                                      integrationID: server.integrationID)
        }
        let skills = (try? await skillList.data)?.compactMap(\.value).sorted { $0.id < $1.id }.map {
            CustomizationLiveData.Skill(id: $0.id, name: $0.name, summary: $0.description, path: $0.path)
        }
        let plugins = ((try? await pluginList.data) ?? []).compactMap(\.value).compactMap { plugin -> CustomizationLiveData.Plugin? in
            switch plugin.source.type {
            case "package":
                guard let target = plugin.source.target else { return nil }
                return .init(id: plugin.id, source: target, isFile: false, failure: plugin.state.status == "failed" ? plugin.state.error : nil)
            case "local":
                guard let path = plugin.source.path else { return nil }
                return .init(id: plugin.id, source: path, isFile: true, failure: plugin.state.status == "failed" ? plugin.state.error : nil)
            default:
                return nil
            }
        }
        return CustomizationLiveData(mcp: mcp, skills: skills, plugins: plugins.sorted { $0.source < $1.source })
    }

    /// `POST /api/experimental/mcp/{server}/disconnect`, then `/connect`.
    public func restartMCPServer(_ name: String, directory: String) async throws {
        let path = "/api/experimental/mcp/\(Self.pathComponent(name))"
        try await sendIgnoringBody("POST", path + "/disconnect", query: Self.location(directory))
        try await sendIgnoringBody("POST", path + "/connect", query: Self.location(directory))
    }

    /// The integration's browser sign-in method, started with `integration.oauth.connect`.
    public func startMCPSignIn(integrationID: String, directory: String) async throws -> OAuthAttempt {
        let integration = try await self.integration(integrationID, directory: directory)
        guard let method = integration.methods.first(where: { $0.kind == .oauth }), let methodID = method.methodID else {
            throw OpenCodeError.invalidArgument("This MCP server has no browser sign-in.")
        }
        return try await startOAuth(integrationID: integrationID, methodID: methodID, directory: directory)
    }

    public func mcpSignInStatus(integrationID: String, attemptID: String, directory: String) async throws -> OAuthAttemptStatus {
        try await oauthStatus(integrationID: integrationID, attemptID: attemptID, directory: directory)
    }
}
