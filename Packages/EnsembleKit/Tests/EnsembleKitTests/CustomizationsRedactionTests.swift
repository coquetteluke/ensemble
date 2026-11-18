import Foundation
import Testing
@testable import EnsembleKit

@Suite("Customizations redaction")
struct CustomizationsRedactionTests {
    let m = CustomizationRedaction.mask

    @Test("Secret-looking names in any case")
    func names() {
        for name in ["GITHUB_TOKEN", "apiKey", "X-Api-Key", "Authorization", "client_secret", "PASSWORD", "db_passwd",
                     "SessionCookie", "private_key_file", "AWS_SECRET_ACCESS_KEY", "Signature"] {
            #expect(CustomizationRedaction.isSecretName(name), "\(name)")
        }
        for name in ["PATH", "DEBUG", "matcher", "command", "url", "DB_READONLY", "timeout"] {
            #expect(!CustomizationRedaction.isSecretName(name), "\(name)")
        }
    }

    @Test("URLs lose credentials, query values and fragments")
    func urls() {
        #expect(CustomizationRedaction.url("https://mcp.example.com/mcp") == "https://mcp.example.com/mcp")
        #expect(CustomizationRedaction.url("https://user:pa55@host.example.com/x") == "https://\(m)@host.example.com/x")
        #expect(CustomizationRedaction.url("https://host/x?api_key=abc&mode=fast") == "https://host/x?api_key=\(m)&mode=\(m)")
        #expect(CustomizationRedaction.url("https://host/cb#access_token=abc") == "https://host/cb#\(m)")
        #expect(CustomizationRedaction.url("wss://a@b@host:8080/ws") == "wss://\(m)@host:8080/ws")
        #expect(CustomizationRedaction.url("https://host/hooks/" + FakeSecret.make("ghp_", 30)) == "https://host/hooks/\(m)")
    }

    @Test("Command lines mask values after secret flags and in NAME=value")
    func commands() {
        #expect(CustomizationRedaction.command(["npx", "-y", "@scope/server", "--root", "/srv"]) == "npx -y @scope/server --root /srv")
        #expect(CustomizationRedaction.command(["srv", "--token", "abc123"]) == "srv --token \(m)")
        #expect(CustomizationRedaction.command(["srv", "--api-key=abc123"]) == "srv --api-key=\(m)")
        #expect(CustomizationRedaction.command(["env", "OPENAI_API_KEY=sk-x", "DEBUG=1", "run"]) == "env OPENAI_API_KEY=\(m) DEBUG=1 run")
        #expect(CustomizationRedaction.command(["srv", "--url", "https://u:p@h/x?k=v"]) == "srv --url https://\(m)@h/x?k=\(m)")
        #expect(CustomizationRedaction.command(["node", "my server.js"]) == "node \"my server.js\"")
    }

    @Test("Free text: headers, pairs, flags and key-shaped strings")
    func text() {
        #expect(CustomizationRedaction.text("curl -H \"Authorization: Bearer abcdef123456\" https://x.example.com")
                    .contains("abcdef123456") == false)
        #expect(CustomizationRedaction.text("export GITHUB_TOKEN=ghx123 && run") == "export GITHUB_TOKEN=\(m) && run")
        #expect(CustomizationRedaction.text("{\"apiKey\": \"abc\"}") == "{\"apiKey\": \(m)}")
        #expect(CustomizationRedaction.text("tool --password hunter2 --verbose") == "tool --password \(m) --verbose")
        #expect(CustomizationRedaction.text("key " + FakeSecret.make("sk-ant-api03-", 22)) == "key \(m)")
        #expect(CustomizationRedaction.text("aws " + FakeSecret.make("AKIA", 16, upper: true)) == "aws \(m)")
        #expect(CustomizationRedaction.text("slack " + FakeSecret.make("xoxb-", 17)) == "slack \(m)")
        #expect(CustomizationRedaction.text("google " + FakeSecret.make("AIzaSy", 33)) == "google \(m)")
        #expect(CustomizationRedaction.text("gitlab " + FakeSecret.make("glpat-", 20)) == "gitlab \(m)")
        #expect(CustomizationRedaction.text("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.sig") == "jwt \(m)")
        #expect(CustomizationRedaction.text("id 0123456789abcdef0123456789abcdef0123") == "id \(m)")
        // Ordinary prose and commands pass through.
        #expect(CustomizationRedaction.text("Run swift test before committing.") == "Run swift test before committing.")
        #expect(CustomizationRedaction.text("./scripts/lint.sh --fix src") == "./scripts/lint.sh --fix src")
        #expect(CustomizationRedaction.text("") == "")
    }

    @Test("An MCP server never carries env or header values")
    func mcpServerKeysOnly() {
        let config: JSONValue = ["command": "srv", "args": ["--secret", "s3cr3t"], "env": ["A_TOKEN": "t0k3n", "PLAIN": "value"],
                                 "headers": ["Authorization": "Bearer abc"]]
        let server = CustomizationsDiscovery.mcpServer(.claude, name: "x", config: config, scope: .user, source: nil, status: .loaded)
        #expect(server.environmentKeys == ["A_TOKEN", "PLAIN"])
        #expect(server.headerKeys == ["Authorization"])
        #expect(server.target == "srv --secret \(m)")
        let dump = String(describing: server)
        for secret in ["s3cr3t", "t0k3n", "value", "Bearer abc"] { #expect(!dump.contains(secret), "\(secret)") }
    }
}

/// Secret-shaped strings for redaction tests, built at runtime so no token-like literal sits in the source
/// (they are not real credentials, and the repository's commit guard rejects anything that looks like one).
enum FakeSecret {
    static func make(_ prefix: String, _ length: Int, upper: Bool = false) -> String {
        let alphabet = Array(upper ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" : "abcdefghijklmnopqrstuvwxyz0123456789")
        return prefix + String((0..<length).map { alphabet[$0 % alphabet.count] })
    }
}

