import Foundation

/// Which folders already have Ensemble's agent tools on this OpenCode server, and the server to ask for them.
struct OpenCodeAgentToolsState: Sendable {
    var tools: (any AgentToolsAttaching)? = AgentToolsServer.shared
    /// Session folders, so each prompt does not look its session up again.
    var directories: [String: String] = [:]
    /// The key each folder's server was added with.
    var attached: [String: String] = [:]
}

extension OpenCodeClient {
    /// Uses another agent tools server (tests), or none.
    public func setAgentTools(_ tools: (any AgentToolsAttaching)?) {
        agentToolsState.withLock {
            $0.tools = tools
            $0.attached = [:]
        }
    }

    /// Adds Ensemble's agent tools to the session's folder on this server before a prompt, once per folder.
    ///
    /// OpenCode 2.3 keeps MCP servers per location, not per session, so one bridge serves the folder
    /// (`AgentToolsTarget.folder`) and each call names its session in `_meta`. The server is added at runtime
    /// (`PUT /api/experimental/mcp/ensemble`, lost when OpenCode restarts, which makes a new client) with Code Mode off,
    /// so the model sees `ensemble_propose_session` and the browser tools as ordinary tools. This works on the private
    /// server for untrusted folders too, since it is not project config. Any failure leaves the session without the
    /// tools; the prompt still goes out.
    func ensureAgentTools(sessionID: String) async {
        guard let tools = agentToolsState.withLock({ $0.tools }), tools.isAttaching else { return }
        var known = agentToolsState.withLock { $0.directories[sessionID] }
        if known == nil {
            guard let info = try? await session(sessionID), !info.directory.isEmpty else { return }
            known = info.directory
            agentToolsState.withLock { $0.directories[sessionID] = info.directory }
        }
        guard let directory = known else { return }
        let target = AgentToolsTarget.folder(directory, server: baseURL.absoluteString)
        guard let attachment = tools.attachment(for: target) else { return }
        // The folder's key speaks only for OpenCode sessions Ensemble prompts on this server.
        tools.allow(openCodeSession: sessionID, on: target)
        if agentToolsState.withLock({ $0.attached[directory] == attachment.key }) { return }
        do {
            try await sendIgnoringBody("PUT", "/api/experimental/mcp/\(AgentToolsAttachment.serverName)",
                                       query: Self.location(directory), body: ["config": attachment.openCodeConfig])
            agentToolsState.withLock { $0.attached[directory] = attachment.key }
        } catch {
            // An OpenCode without runtime MCP servers, or one that refused: the session works without the tools.
        }
    }
}
