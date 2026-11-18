#if os(macOS)
import Foundation

extension ClaudeEngineCore {
    /// Writes the agent tools' `--mcp-config` file for a session into `folder` (the private folder the settings
    /// snapshot already uses), or into a new private folder (0700, file 0600). Returns the folder and the flags, or nil
    /// when the tools are not running or the file cannot be written; the agent then starts without them.
    ///
    /// The CLI merges every `--mcp-config` it is given, and these files apply with `--setting-sources user` too, so the
    /// tools reach agents in folders that are not trusted while the project's own `.mcp.json` stays out.
    ///
    /// The key is tied to this file (`AgentToolsBinding.claude`): a helper may use it only when its parent is a `claude`
    /// process Ensemble started with exactly this `--mcp-config`, so a key read from another process's environment
    /// cannot be used from an agent's shell or from another session's `claude`.
    static func agentToolsFile(_ tools: (any AgentToolsAttaching)?, sessionID: String, folder: URL?) -> (folder: URL, arguments: [String])? {
        guard let tools, let attachment = tools.attachment(for: .session(sessionID)) else { return nil }
        let data = attachment.claudeConfig.lineData
        let written: (folder: URL, arguments: [String])
        if let folder {
            let url = folder.appendingPathComponent("agent-tools.json")
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
            written = (folder, ["--mcp-config", url.path])
        } else {
            guard let made = try? writePrivateFiles([("agent-tools.json", data, "--mcp-config")]) else { return nil }
            written = made
        }
        guard let path = written.arguments.last else { return nil }
        tools.expect(.claude(configPath: path), for: .session(sessionID))
        return written
    }
}
#endif
