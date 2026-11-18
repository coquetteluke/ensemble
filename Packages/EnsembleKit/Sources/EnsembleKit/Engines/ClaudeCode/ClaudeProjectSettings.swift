import CryptoKit
import Foundation

/// A project's own Claude Code settings: `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json`.
///
/// Headless `claude -p` skips Claude Code's "Do you trust this folder?" question, so these files would run with the
/// user's rights as soon as an agent starts (verified 2026-11-18 with claude 2.1.319: with `--setting-sources
/// user,project,local` a project's SessionStart hook and its `.mcp.json` server both ran with no prompt; with
/// `--setting-sources user` neither did). The engine therefore loads them only for folders in `WorkspaceTrust`.
enum ClaudeProjectSettings {
    /// `env` keys that send requests, and with them an API key, somewhere else or change which credentials are used.
    static let credentialEnvKeys: Set<String> = [
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy", "NO_PROXY", "no_proxy",
        "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED", "SSL_CERT_FILE", "SSL_CERT_DIR",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
        "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
    ]
    /// Every `env` key with this prefix counts (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
    /// `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_BEDROCK_BASE_URL`, ...).
    static let credentialEnvPrefix = "ANTHROPIC_"
    /// Top-level settings that run a program to produce credentials.
    static let credentialSettingKeys: Set<String> = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper"]

    struct Overrides: Equatable, Sendable {
        /// What was found, for the message (`ANTHROPIC_BASE_URL`, `apiKeyHelper`, ...). Values are never shown.
        var keys: [String]
        /// A hash of the files' relevant values, so a confirmation stops counting once they change.
        var fingerprint: String
    }

    /// The project settings files for a session folder: in the folder and in each folder above it, stopping before the
    /// home folder (whose `.claude/settings.json` is the user's own settings).
    static func settingsFiles(directory: String, home: String = NSHomeDirectory()) -> [URL] {
        guard let start = WorkspaceTrust.resolvedPath(directory) else { return [] }
        let homeResolved = WorkspaceTrust.resolvedPath(home) ?? home
        var result: [URL] = []
        var current = start
        let fm = FileManager.default
        while current != "/" && current != homeResolved && !current.isEmpty {
            for name in ["settings.json", "settings.local.json"] {
                let file = URL(fileURLWithPath: current).appendingPathComponent(".claude").appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) { result.append(file) }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    /// True when the folder has Claude settings or MCP servers of its own that an untrusted session leaves out.
    static func hasOwnSettings(directory: String, home: String = NSHomeDirectory()) -> Bool {
        if !settingsFiles(directory: directory, home: home).isEmpty { return true }
        guard let resolved = WorkspaceTrust.resolvedPath(directory) else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: resolved).appendingPathComponent(".mcp.json").path)
    }

    /// Credential and endpoint settings in the project's own settings files, or nil when there are none. A file that
    /// cannot be read as JSON counts as one, since what it would do cannot be checked.
    static func credentialOverrides(directory: String, home: String = NSHomeDirectory()) -> Overrides? {
        var keys: [String] = []
        var lines: [String] = []
        for file in settingsFiles(directory: directory, home: home) {
            let label = file.deletingLastPathComponent().deletingLastPathComponent().path + "/.claude/" + file.lastPathComponent
            guard let data = try? Data(contentsOf: file), let json = JSONValue.parse(data: data), case .object(let object) = json else {
                keys.append("unreadable \(label)")
                let digest = (try? Data(contentsOf: file)).map { SHA256.hash(data: $0).description } ?? "missing"
                lines.append("\(label)\tunreadable\t\(digest)")
                continue
            }
            for (key, value) in object where credentialSettingKeys.contains(key) {
                keys.append(key)
                lines.append("\(label)\t\(key)\t\(value.jsonText)")
            }
            for (key, value) in object["env"]?.objectValue ?? [:]
                where key.hasPrefix(credentialEnvPrefix) || credentialEnvKeys.contains(key) {
                keys.append(key)
                lines.append("\(label)\tenv.\(key)\t\(value.jsonText)")
            }
        }
        guard !keys.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return Overrides(keys: Array(Set(keys)).sorted(), fingerprint: fingerprint)
    }
}
