import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of rewind with choices and per-session copies: the rewind sheet for each engine (Claude: every choice but
/// summarize, with the file list; OpenCode: no code-only or summarize, conversation only chosen, with a failure line;
/// Gemini: nothing available), the notice with Redo in each state, the composer's "Work in a copy" switch and branch
/// chip in each state, the branch menu, the new-session sheet's copy option, Settings' Worktrees section with session and
/// room copies, and the usage popover with Show all usage. Dark and
/// light at the requested zoom. Called from `SnapshotRenderer.run`. Nothing touches git or the disk.
@MainActor
enum RewindSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let store = makeStore()
        let window = WindowState()
        for scheme in [ColorScheme.dark, .light] {
            let tone = (scheme == .dark ? "dark" : "light") + suffix
            written += save("rewind-sheet-claude-\(tone)", to: directory, width: 500, zoom: zoom, scheme: scheme) {
                RewindSheet(request: claudeRequest, confirmUnavailableReason: nil, onSelect: { _ in }, onCancel: {}, onConfirm: {})
            }
            written += save("rewind-sheet-opencode-\(tone)", to: directory, width: 500, zoom: zoom, scheme: scheme) {
                RewindSheet(request: openCodeRequest, confirmUnavailableReason: nil, onSelect: { _ in }, onCancel: {}, onConfirm: {})
            }
            written += save("rewind-sheet-gemini-\(tone)", to: directory, width: 500, zoom: zoom, scheme: scheme) {
                RewindSheet(request: geminiRequest, confirmUnavailableReason: "Choose what to rewind", onSelect: { _ in },
                            onCancel: {}, onConfirm: {})
            }
            written += save("rewind-sheet-states-\(tone)", to: directory, width: 500, zoom: zoom, scheme: scheme) {
                SheetStates()
            }
            written += save("rewind-notices-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                Notices()
            }
            written += save("worktree-composer-\(tone)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                ComposerStates(store: store, window: window)
            }
            written += save("worktree-branch-menu-\(tone)", to: directory, width: 300, zoom: zoom, scheme: scheme) {
                BranchMenuContent(branches: branches, current: "ensemble/session-ab12cd34") { _ in }
                    .padding(10)
            }
            written += save("worktree-new-session-\(tone)", to: directory, width: 900, zoom: zoom, scheme: scheme) {
                NewSessionPage(store: store, window: window, initialDirectory: folder, initialWorktree: true)
                    .frame(height: 620)
            }
            written += save("usage-popover-show-all-\(tone)", to: directory, width: 240, zoom: zoom, scheme: scheme) {
                UsagePopover(usage: Usage(inputTokens: 182_000, outputTokens: 24_500, cacheReadTokens: 410_000, costUSD: 1.84),
                             title: "Tokenizer split", store: store) {}
            }
            written += save("worktree-settings-\(tone)", to: directory, width: 640, zoom: zoom, scheme: scheme) {
                SettingsSectionCard { WorktreesSettingsSection(store: store) }
            }
        }
        print("Rendered \(written.count) rewind and worktree snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Samples

    static let folder = "/Users/sam/Projects/widgets"
    static let copyPath = folder + "/.ensemble/worktrees/session-ab12cd34"
    static let copyBranch = "ensemble/session-ab12cd34"

    static let claudeFiles = [
        FileChange(path: "Sources/Widgets/Parser.swift", kind: .modified, additions: 18, deletions: 64),
        FileChange(path: "Sources/Widgets/TokenStream.swift", kind: .deleted, additions: 0, deletions: 112),
        FileChange(path: "Tests/WidgetsTests/ParserTests.swift", kind: .modified, additions: 3, deletions: 21),
        FileChange(path: "docs/parser.md", kind: .added),
    ]

    static let claudeRequest = RewindRequest(
        sessionID: "claude", messageID: "m", messageText: "Split the parser into a tokenizer and a tree builder",
        phase: .ready(RewindPlan(choices: [
            RewindChoice(.codeAndConversation), RewindChoice(.conversationOnly), RewindChoice(.codeOnly),
            RewindChoice(.summarizeFromHere, unavailableReason: "Claude offers this only in its own terminal"),
        ], files: claudeFiles, filesNote: "Changes made by shell commands are not put back.", messagesRemoved: 2, canRedo: true)),
        selected: .codeAndConversation)

    static let openCodeRequest = RewindRequest(
        sessionID: "opencode", messageID: "m", messageText: "Rename the settings keys and migrate old files",
        phase: .ready(RewindPlan(choices: [
            RewindChoice(.codeAndConversation), RewindChoice(.conversationOnly),
            RewindChoice(.codeOnly, unavailableReason: "OpenCode puts files back only together with the conversation"),
            RewindChoice(.summarizeFromHere, unavailableReason: "OpenCode can summarize only the whole conversation (/compact)"),
        ], files: Array(claudeFiles.prefix(3)), messagesRemoved: 1, canRedo: true)),
        selected: .conversationOnly,
        error: "Could not rewind: OpenCode returned 409: the session is busy")

    static let geminiRequest = RewindRequest(
        sessionID: "gemini", messageID: "m", messageText: "Draft the release notes",
        phase: .ready(.unavailable(RewindReason.noRewind("Google Antigravity"))), selected: nil)

    static let branches = [
        SessionBranch(name: copyBranch, isCurrent: true),
        SessionBranch(name: "feature/tokenizer"),
        SessionBranch(name: "fix/flaky-parser-test"),
        SessionBranch(name: "main", checkedOutAt: folder),
        SessionBranch(name: "ensemble/session-9f31c2aa", checkedOutAt: folder + "/.ensemble/worktrees/session-9f31c2aa"),
    ]

    static let emptyID = "ses_wt_empty"
    static let copyEmptyID = "ses_wt_copy_empty"
    static let copyWorkedID = "ses_wt_copy_worked"
    static let untrustedID = "ses_wt_untrusted"
    static let untrustedFolder = "/Users/sam/Downloads/someone-elses-repo"

    /// Four sessions: an empty one in a repository, an empty one in its copy, one in its copy with messages, and an
    /// empty one in an untrusted repository. Worktree state is seeded; no git runs.
    static func makeStore() -> SessionStore {
        let base = PreviewData.seed()
        let now = Date()
        let sessions = [
            EngineSession(id: emptyID, title: "New session", directory: folder, model: base.models.first?.ref),
            EngineSession(id: copyEmptyID, title: "New session", directory: copyPath, model: base.models.first?.ref),
            EngineSession(id: copyWorkedID, title: "Tokenizer split", directory: folder + "/.ensemble/worktrees/session-9f31c2aa",
                          model: base.models.first?.ref, updated: now.addingTimeInterval(-3 * 3600)),
            EngineSession(id: untrustedID, title: "New session", directory: untrustedFolder, model: base.models.first?.ref),
            EngineSession(id: "ses_wt_archived", title: "Try a faster lexer", directory: folder + "/.ensemble/worktrees/session-3c0de111",
                          model: base.models.first?.ref, updated: now.addingTimeInterval(-9 * 86400), archived: true),
        ]
        let seed = StoreSeed(sessions: sessions, transcripts: [
            copyWorkedID: [.user(id: "u1", text: "Split the parser", date: now.addingTimeInterval(-3 * 3600)),
                           .agentText(id: "a1", text: "Done.", agentID: nil, streaming: false)],
        ], models: base.models, providers: base.providers, selectedSessionID: emptyID)
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0))
        store.seed(seed)
        let records = [
            SessionWorktreeRecord(id: "ab12cd34", sessionID: copyEmptyID, home: folder, path: copyPath, sessionDirectory: copyPath,
                                  branch: copyBranch, baseBranch: "main", created: now.addingTimeInterval(-60), lastUsed: now.addingTimeInterval(-60)),
            SessionWorktreeRecord(id: "9f31c2aa", sessionID: copyWorkedID, home: folder, path: folder + "/.ensemble/worktrees/session-9f31c2aa",
                                  sessionDirectory: folder + "/.ensemble/worktrees/session-9f31c2aa", branch: "ensemble/session-9f31c2aa",
                                  baseBranch: "main", created: now.addingTimeInterval(-86400), lastUsed: now.addingTimeInterval(-3 * 3600)),
            SessionWorktreeRecord(id: "3c0de111", sessionID: "ses_wt_archived", home: folder,
                                  path: folder + "/.ensemble/worktrees/session-3c0de111",
                                  sessionDirectory: folder + "/.ensemble/worktrees/session-3c0de111", branch: "ensemble/session-3c0de111",
                                  baseBranch: "main", created: now.addingTimeInterval(-12 * 86400), lastUsed: now.addingTimeInterval(-9 * 86400)),
            SessionWorktreeRecord(id: "77aa0e5d", sessionID: "ses_gone", home: "/Users/sam/Projects/site",
                                  path: "/Users/sam/Projects/site/.ensemble/worktrees/session-77aa0e5d",
                                  sessionDirectory: "/Users/sam/Projects/site/.ensemble/worktrees/session-77aa0e5d",
                                  branch: "ensemble/session-77aa0e5d", baseBranch: "main",
                                  created: now.addingTimeInterval(-30 * 86400), lastUsed: now.addingTimeInterval(-21 * 86400)),
        ]
        store.worktrees.seedPreview(
            records: records,
            statuses: [
                SessionWorktreeStatus(record: records[1], exists: true, branch: "feature/tokenizer",
                                      changedFiles: ["Sources/Widgets/Lexer.swift", "Sources/Widgets/Parser.swift", "notes.md"],
                                      sizeBytes: 48_300_000),
                SessionWorktreeStatus(record: records[0], exists: true, branch: copyBranch, changedFiles: [], sizeBytes: 47_900_000),
                SessionWorktreeStatus(record: records[2], exists: true, branch: records[2].branch, changedFiles: [], sizeBytes: 51_200_000),
                SessionWorktreeStatus(record: records[3], exists: true, branch: records[3].branch,
                                      changedFiles: ["index.html"], sizeBytes: 3_400_000),
                SessionWorktreeStatus(record: roomCopy("ensemble-design-ada", agent: "Ada", finished: false, now: now), exists: true,
                                      branch: "ensemble/design/ada", changedFiles: [], sizeBytes: 47_100_000),
                SessionWorktreeStatus(record: roomCopy("ensemble-design-grace", agent: "Grace", finished: true, now: now), exists: true,
                                      branch: "ensemble/design/grace", changedFiles: [], sizeBytes: 47_200_000),
            ],
            availability: [folder: "", untrustedFolder: "Trust this folder to work in a copy"],
            currentBranch: [emptyID: "main", copyEmptyID: copyBranch, copyWorkedID: "feature/tokenizer", untrustedID: "main"],
            branches: [copyEmptyID: branches, copyWorkedID: branches])
        return store
    }

    static func roomCopy(_ name: String, agent: String, finished: Bool, now: Date) -> SessionWorktreeRecord {
        SessionWorktreeRecord(id: "room-\(name)", home: folder, path: folder + "/.ensemble/worktrees/\(name)", sessionDirectory: folder,
                              branch: "ensemble/design/\(agent.lowercased())", baseBranch: "main",
                              created: now.addingTimeInterval(-2 * 86400), lastUsed: now.addingTimeInterval(finished ? -2 * 86400 : -600),
                              room: RoomCopyInfo(roomID: UUID(), roomTitle: "Settings redesign", agentName: agent, finished: finished))
    }

    // MARK: Views

    /// A grouped settings section as the Settings window draws it (`ImageRenderer` cannot draw a `Form`).
    private struct SettingsSectionCard<Content: View>: View {
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme
        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(12)) {
                content
            }
            .font(theme.font(size: 13))
            .padding(theme.z(16))
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
            .padding(theme.z(20))
        }
    }

    private struct Label: View {
        let text: String
        @Environment(\.theme) private var theme
        var body: some View {
            Text(text)
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private struct SheetStates: View {
        @Environment(\.theme) private var theme
        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(10)) {
                Label(text: "Reading the plan").padding(.horizontal, theme.z(22)).padding(.top, theme.z(12))
                RewindSheet(request: RewindRequest(sessionID: "s", messageID: "m", messageText: "Add a dark mode toggle"),
                            confirmUnavailableReason: nil, onSelect: { _ in }, onCancel: {}, onConfirm: {})
                Label(text: "Rewinding").padding(.horizontal, theme.z(22))
                RewindSheet(request: RewindRequest(sessionID: "s", messageID: "m", messageText: "Add a dark mode toggle",
                                                   phase: .working(RewindPlan(choices: [RewindChoice(.codeAndConversation),
                                                                                        RewindChoice(.conversationOnly)],
                                                                              files: [claudeFiles[0]], messagesRemoved: 1, canRedo: true),
                                                                   .codeAndConversation),
                                                   selected: .codeAndConversation),
                            confirmUnavailableReason: nil, onSelect: { _ in }, onCancel: {}, onConfirm: {})
                Label(text: "The agent started working").padding(.horizontal, theme.z(22))
                RewindSheet(request: claudeRequest, confirmUnavailableReason: RewindReason.working, onSelect: { _ in },
                            onCancel: {}, onConfirm: {})
            }
        }
    }

    private struct Notices: View {
        @Environment(\.theme) private var theme
        var body: some View {
            let files = Array(claudeFiles.prefix(3))
            VStack(alignment: .leading, spacing: theme.z(14)) {
                Label(text: "After a rewind, Redo available")
                RewindNoticeRow(notice: RewindNotice(id: "n1", sessionID: "s",
                                                     outcome: RewindOutcome(scope: .codeAndConversation, files: files, messagesRemoved: 2, canRedo: true)),
                                redoUnavailableReason: nil, onRedo: {})
                Label(text: "Conversation only, agent working")
                RewindNoticeRow(notice: RewindNotice(id: "n2", sessionID: "s",
                                                     outcome: RewindOutcome(scope: .conversationOnly, messagesRemoved: 1, canRedo: true)),
                                redoUnavailableReason: RewindReason.working, onRedo: {})
                Label(text: "Code only, conversation moved on (no Redo)")
                RewindNoticeRow(notice: RewindNotice(id: "n3", sessionID: "s",
                                                     outcome: RewindOutcome(scope: .codeOnly, files: [files[0]], canRedo: true)),
                                redoUnavailableReason: "The conversation has moved on since", onRedo: {})
                Label(text: "Redo ran")
                RewindNoticeRow(notice: RewindNotice(id: "n4", sessionID: "s",
                                                     outcome: RewindOutcome(scope: .codeAndConversation, files: files, messagesRemoved: 2, canRedo: true),
                                                     state: .redone),
                                redoUnavailableReason: nil, onRedo: {})
                Label(text: "Engine without Redo")
                RewindNoticeRow(notice: RewindNotice(id: "n5", sessionID: "s",
                                                     outcome: RewindOutcome(scope: .codeAndConversation, messagesRemoved: 3, canRedo: false)),
                                redoUnavailableReason: nil, onRedo: {})
            }
            .padding(theme.z(24))
        }
    }

    /// The real composer and status line for each session.
    private struct ComposerStates: View {
        let store: SessionStore
        let window: WindowState
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(10)) {
                ForEach(cases, id: \.0) { id, title in
                    if let session = store.session(id) {
                        Label(text: title)
                        VStack(spacing: 0) {
                            ComposerView(store: store, session: session, window: window)
                            StatusLine(store: store, session: session, window: window)
                        }
                    }
                }
            }
            .padding(theme.z(16))
        }

        private var cases: [(String, String)] {
            [(emptyID, "New session in a git repository: switch off, project branch"),
             (copyEmptyID, "Switch on: a copy on its own branch, before the first message"),
             (copyWorkedID, "In a copy after the first message: branch chip only, switched to another branch"),
             (untrustedID, "Untrusted folder: switch off and disabled")]
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
            .environment(SnapshotRenderer.power)
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
