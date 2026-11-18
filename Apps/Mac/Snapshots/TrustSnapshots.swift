import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of workspace trust: every kind of trust card (one sheet per colour scheme), the card docked above the
/// pull request bar and the composer, the new-session sheet's trust line in each state, and the whole new-session
/// sheet for an untrusted folder with project files. Dark and light at the requested zoom. Called from
/// `SnapshotRenderer.run`. The sample folder is a temporary one; nothing is trusted.
@MainActor
enum TrustSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        let window = WindowState()
        let folder = sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("trust-cards-\(tone)\(suffix)", to: directory, width: 784, zoom: zoom, scheme: scheme) {
                CardsSheet(cases: cases())
            }
            written += save("trust-sheet-lines-\(tone)\(suffix)", to: directory, width: 460, zoom: zoom, scheme: scheme) {
                LinesSheet(cases: lineCases())
            }
            if let session = store.session(PreviewData.mainSessionID) {
                written += save("trust-conversation-bottom-\(tone)\(suffix)", to: directory, width: 784, zoom: zoom, scheme: scheme) {
                    ConversationBottom(store: store, session: session, window: window, prompt: openCodeSkipped)
                }
            }
            written += save("trust-new-session-\(tone)\(suffix)", to: directory, width: 460, zoom: zoom, scheme: scheme) {
                NewSessionSheet(store: store, window: window, initialDirectory: folder.path)
            }
        }
        print("Rendered \(written.count) trust snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Samples

    static let folder = "/Users/sam/Projects/widgets"

    static let openCodeSkipped = TrustPrompt(
        kind: .skipped, folder: folder, engineName: "OpenCode", files: ["opencode.json", ".opencode/", "AGENTS.md"],
        title: "OpenCode is running without this folder's config",
        message: "You have not trusted this folder, so this session skips opencode.json, .opencode/ and AGENTS.md. Trusting it "
            + "loads them in new sessions here. This session keeps running without them.")

    struct Case: Identifiable {
        let title: String
        let prompt: TrustPrompt
        var error: String?
        var id: String { title }
    }

    static func cases() -> [Case] {
        [
            Case(title: "Claude, untrusted folder with settings", prompt: TrustPrompt(
                kind: .skipped, folder: folder, engineName: "Claude", files: [".claude/settings.json", ".mcp.json"],
                title: "Claude is running without this folder's settings",
                message: "You have not trusted this folder, so Claude uses your own settings only and skips "
                    + ".claude/settings.json and .mcp.json. Trust it to load them from your next message.")),
            Case(title: "OpenCode, untrusted folder (private server)", prompt: openCodeSkipped),
            Case(title: "Gemini, untrusted folder", prompt: TrustPrompt(
                kind: .refused, folder: folder, engineName: "Gemini", files: [".agents/", "GEMINI.md"],
                title: "Gemini only runs in folders you trust",
                message: "Gemini loads a folder's own hooks, rules and plugins and cannot be told to skip them, so Ensemble "
                    + "does not start it in a folder you have not trusted. This folder has .agents/ and GEMINI.md.")),
            Case(title: "Gemini, Trust this folder on the home folder", prompt: TrustPrompt(
                kind: .refused, folder: "/Users/sam", engineName: "Gemini", files: [],
                title: "Gemini only runs in folders you trust",
                message: "Gemini loads a folder's own hooks, rules and plugins and cannot be told to skip them, so Ensemble "
                    + "does not start it in a folder you have not trusted."),
                 error: WorkspaceTrustError.tooBroad("/Users/sam").errorDescription),
            Case(title: "OpenCode, a model whose browser sign-in only the shared service has", prompt: TrustPrompt(
                kind: .refused, folder: folder, engineName: "OpenCode", files: [],
                title: "This session cannot use its model's sign-in",
                message: "This provider's sign-in works only in trusted folders. Trust this folder, then start a new "
                    + "session here to use it.")),
            Case(title: "After trusting, a refused message", prompt: TrustPrompt(
                kind: .retry, folder: folder, engineName: "Gemini", files: [], title: "Folder trusted",
                message: "Gemini can start here now. Send the message it refused again.")),
            Case(title: "Trusted later, OpenCode session on the private server", prompt: TrustPrompt(
                kind: .keepsSkipping, folder: folder, engineName: "OpenCode", files: ["opencode.json", "AGENTS.md"],
                title: "This session still runs without the folder's config",
                message: "It started before you trusted this folder, so it keeps skipping opencode.json and AGENTS.md. "
                    + "New sessions here load them.")),
            Case(title: "Older OpenCode session on the shared service", prompt: TrustPrompt(
                kind: .loadsUntrusted, folder: folder, engineName: "OpenCode", files: ["opencode.json"],
                title: "This session loads the folder's config",
                message: "It started on the shared OpenCode service, which loads opencode.json although you have not "
                    + "trusted this folder. Trust the folder, or start a new session here to run without it.")),
        ]
    }

    struct LineCase: Identifiable {
        let title: String
        let line: NewSessionTrustLine
        var error: String?
        var id: String { title }
    }

    static func lineCases() -> [LineCase] {
        [
            LineCase(title: "Trusted", line: NewSessionTrustLine(text: "Trusted. Agents load this folder's own settings.",
                                                                 tone: .trusted, offersTrust: false)),
            LineCase(title: "Untrusted, with settings", line: NewSessionTrustLine(
                text: "Not trusted. The agent skips .claude/settings.json and .mcp.json.", tone: .untrusted, offersTrust: true)),
            LineCase(title: "Untrusted, instructions only", line: NewSessionTrustLine(
                text: "Not trusted. The agent skips AGENTS.md.", tone: .untrusted, offersTrust: false)),
            LineCase(title: "Untrusted, nothing of its own", line: NewSessionTrustLine(
                text: "Not trusted. This folder has no agent settings of its own.", tone: .untrusted, offersTrust: false)),
            LineCase(title: "Gemini model", line: NewSessionTrustLine(
                text: "Not trusted. Gemini only starts in folders you trust.", tone: .blocked, offersTrust: true)),
            LineCase(title: "OpenCode model with a browser sign-in", line: NewSessionTrustLine(
                text: SessionStore.signInNeedsTrustText, tone: .blocked, offersTrust: true)),
            LineCase(title: "Trust refused", line: NewSessionTrustLine(
                text: "Not trusted. Gemini only starts in folders you trust.", tone: .blocked, offersTrust: true),
                     error: WorkspaceTrustError.tooBroad("/Users/sam").errorDescription),
        ]
    }

    /// A temporary untrusted project folder with Claude and OpenCode files, for the whole sheet.
    private static func sampleFolder() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ensemble-trust-\(UUID().uuidString.prefix(8))")
        let folder = base.appendingPathComponent("widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        for name in [".mcp.json", ".claude/settings.json", "opencode.json", "AGENTS.md"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }
        return folder
    }

    // MARK: Views

    private struct CardsSheet: View {
        let cases: [Case]
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(14)) {
                ForEach(cases) { item in
                    VStack(alignment: .leading, spacing: theme.z(5)) {
                        Text(item.title)
                            .font(theme.font(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                        TrustCardView(prompt: item.prompt, error: item.error, onTrust: {}, onDismiss: {})
                    }
                }
            }
            .padding(theme.z(12))
        }
    }

    private struct LinesSheet: View {
        let cases: [LineCase]
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(14)) {
                ForEach(cases) { item in
                    VStack(alignment: .leading, spacing: theme.z(5)) {
                        Text(item.title)
                            .font(theme.font(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                        NewSessionTrustRow(line: item.line, error: item.error) {}
                    }
                }
            }
            .padding(theme.z(22))
        }
    }

    /// The bottom of a conversation as `ConversationView` stacks it: trust card, pull request bar, composer, status line.
    private struct ConversationBottom: View {
        let store: SessionStore
        let session: SessionModel
        let window: WindowState
        let prompt: TrustPrompt
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(spacing: 0) {
                TrustCardView(prompt: prompt, onTrust: {}, onDismiss: {})
                    .padding(.bottom, theme.z(8))
                PullRequestBar(controller: .preview(
                    state: .pullRequest(GitHubSnapshots.pr(checks: [.pass, .pending, .pending], review: .reviewRequired)),
                    local: GitHubSnapshots.local(), cli: GitHubSnapshots.signedIn))
                ComposerView(store: store, session: session, window: window)
                StatusLine(store: store, session: session, window: window)
            }
            .padding(.horizontal, theme.z(12))
            .padding(.vertical, theme.z(12))
        }
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = Canvas(width: w) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }

    private struct Canvas<Content: View>: View {
        let width: CGFloat
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.background)
        }
    }
}
