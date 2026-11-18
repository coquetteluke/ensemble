import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the review pane: the whole pane, the file list, a diff with comments and the comment editor,
/// the commit box, and a room's review with agent names. Each in dark and light at the requested zoom.
/// Called from `SnapshotRenderer.run`.
@MainActor
enum ReviewSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        let session = sessionModel()
        let room = roomModel()
        let diffFile = session.files.first { $0.path.hasSuffix("DiffView.swift") }
        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            written += save("review-pane-\(suffix)", to: directory, width: 560, height: 980, zoom: zoom, scheme: scheme) {
                ReviewPane(model: session)
            }
            written += save("review-files-\(suffix)", to: directory, width: 560, height: nil, zoom: zoom, scheme: scheme) {
                ReviewFileList(model: session) { _ in }
            }
            if let diffFile {
                written += save("review-diff-comments-\(suffix)", to: directory, width: 640, height: nil, zoom: zoom, scheme: scheme) {
                    ReviewFileSection(model: session, file: diffFile)
                        .padding(.bottom, 10)
                }
            }
            written += save("review-commit-\(suffix)", to: directory, width: 560, height: nil, zoom: zoom, scheme: scheme) {
                ReviewFooter(model: session)
            }
            written += save("review-room-\(suffix)", to: directory, width: 560, height: 560, zoom: zoom, scheme: scheme) {
                ReviewPane(model: room)
            }
        }
        written += checkLive(to: directory)
        return written
    }

    // MARK: Live check

    /// With `ENSEMBLE_REVIEW_CHECK_REPO` set to a throwaway git repository that has a committed `notes.txt`, runs
    /// the real pane against it in a window that is never shown: a turn snapshot, two edits, load, a comment
    /// sent, Write message, stage and commit. Prints one line and saves `review-pane-live.png`. Without the
    /// variable nothing runs, so normal snapshot runs never touch a repository.
    private static func checkLive(to directory: URL) -> [String] {
        guard let repo = ProcessInfo.processInfo.environment["ENSEMBLE_REVIEW_CHECK_REPO"], !repo.isEmpty else { return [] }
        let target = ReviewTarget.session(id: "ses_live", title: "Live check", directory: repo, created: Date())
        let snapshots = GitTurnSnapshots(fileURL: nil)
        final class Sent { var texts: [String] = [] }
        let sent = Sent()
        let environment = ReviewEnvironment(currentTarget: { target }, engineData: { _ in ReviewEngineData() },
                                            send: { text, _ in sent.texts.append(text) },
                                            draftMessage: { _, _ in "Update the notes" }, isAgentWorking: { _ in false })
        let model = ReviewModel(target: target, environment: environment, snapshots: snapshots)
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { spin(0.05) }
        }

        var snapshotTaken = false
        Task { @MainActor in
            snapshotTaken = await snapshots.recordTurnStart(sessionID: "ses_live", directory: repo) != nil
        }
        wait { snapshotTaken }
        let notes = URL(fileURLWithPath: repo).appendingPathComponent("notes.txt")
        let old = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        try? (old + "A line the agent added\n").write(to: notes, atomically: true, encoding: .utf8)
        try? "new\n".write(to: URL(fileURLWithPath: repo).appendingPathComponent("new file é.txt"), atomically: true, encoding: .utf8)

        let root = ReviewPane(model: model)
            .frame(width: 560, height: 900)
            .ensembleTheme()
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        wait { model.result != nil }
        let loaded = model.files.map(\.path).sorted() == ["new file é.txt", "notes.txt"]
        spin(0.4)
        var paths: [String] = []
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = directory.appendingPathComponent("review-pane-live.png")
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil { paths.append(url.path) }
        }

        var done = false
        var commented = false, wrote = false, staged = false, committed = false
        Task { @MainActor in
            if let file = model.files.first(where: { $0.path == "notes.txt" }),
               let line = model.parsed[file.id]?.lines.first(where: { $0.kind == .addition }) {
                model.beginComment(file: file, line: line)
                model.draft?.text = "Say why this line is needed"
                model.saveDraft()
                await model.sendComments()
                commented = sent.texts.count == 1 && sent.texts[0].contains("notes.txt, line") && model.comments.isEmpty
                await model.writeMessage()
                wrote = model.commitMessage == "Update the notes"
                await model.toggleStage(file)
                staged = model.files.first { $0.path == "notes.txt" }?.stage == .staged
                await model.commit()
                committed = model.lastCommit != nil && model.files.first { $0.path == "notes.txt" }?.stage == .committed
                    && model.files.first { $0.path == "new file é.txt" }?.stage == .untracked
            }
            done = true
        }
        wait { done }
        window.close()
        print("Review check: snapshot \(snapshotTaken), files load \(loaded), comment sent \(commented), write message \(wrote), "
              + "stage \(staged), commit \(committed)")
        return paths
    }

    // MARK: Sample data

    static let root = "/Projects/Ensemble"

    static func sessionModel() -> ReviewModel {
        let target = ReviewTarget.session(id: "ses_review", title: "Add the review pane", directory: root, created: Date())
        let diffView = file("Packages/EnsembleKit/Sources/EnsembleKit/UI/DiffView.swift", .modified, stage: .partial, patch: diffViewPatch)
        var diff = diffView
        let hunks = GitDiffParsing.hunks(in: diffViewPatch)
        let header = GitDiffParsing.fileHeader(diffViewPatch)
        diff.hunkActions = [
            0: ReviewHunkAction(kind: .unstage, patch: header + hunks[0].text),
            1: ReviewHunkAction(kind: .stage, patch: header + hunks[1].text),
        ]
        let files = [
            file("Apps/Mac/Review/ReviewPane.swift", .added, stage: .untracked, patch: newFilePatch),
            diff,
            file("Apps/Mac/Main/MainView.swift", .modified, stage: .staged, patch: mainViewPatch),
            file("docs/PROGRESS.md", .modified, stage: .unstaged, patch: progressPatch),
            file("Apps/Mac/Placeholders/ReviewPlaceholder.swift", .deleted, stage: .unstaged, patch: deletedPatch),
            file("Packages/EnsembleKit/Sources/EnsembleKit/Store/GitRunner.swift", .renamed, stage: .staged,
                 patch: renamePatch, oldPath: "Packages/EnsembleKit/Sources/EnsembleKit/Rooms/GitRunner.swift"),
            ReviewFileDiff(root: root, path: "Apps/Mac/Assets.xcassets/Review.imageset/review.png", kind: .added, isBinary: true, stage: .untracked),
        ]
        let result = ReviewResult(files: files, isGit: true, comparison: "Compared with the folder before the first turn")
        let comments = [
            ReviewComment(fileID: diff.id, path: diff.path, line: 60, side: .new, quoted: "    let parsed: ParsedDiff",
                          text: "Keep a way to build this from plain text too, the tool cards still pass a string."),
            ReviewComment(fileID: diff.id, path: diff.path, line: 63, side: .old, quoted: "    @State private var showAll = false",
                          text: "Why does every diff start expanded now?"),
        ]
        let draft = ReviewCommentDraft(key: ReviewLineKey(fileID: diff.id, side: .new, line: 117), path: diff.path,
                                       quoted: "                .frame(maxWidth: .infinity, alignment: .leading)", agentID: nil,
                                       text: "Add a test with a line longer than the pane.", editing: nil)
        let model = ReviewModel.preview(target: target, result: result, comments: comments, draft: draft,
                                        commitMessage: "Add the review pane with line comments and staging",
                                        lineCounts: [diff.id: 420])
        model.collapsed = Set(files.map(\.id)).subtracting([diff.id])
        return model
    }

    static func roomModel() -> ReviewModel {
        let ada = UUID()
        let bo = UUID()
        let worktree = root + "/.ensemble/worktrees/ensemble-review-room-ada"
        let target = ReviewTarget(id: "room:sample", title: "Review room", directory: root, created: Date(), sessionIDs: ["s1", "s2"],
                                  agents: [
                                      ReviewAgentSource(id: ada, name: "Ada", colorHex: "#8B7CF6", sessionID: "s1", worktree: worktree, baseBranch: "main"),
                                      ReviewAgentSource(id: bo, name: "Bo", colorHex: "#3FB950", sessionID: "s2"),
                                  ])
        var a = file("Sources/Parser.swift", .modified, stage: .unstaged, patch: parserPatch)
        a.root = worktree
        a.agentID = ada
        var b = file("Sources/Parser+Tests.swift", .added, stage: .untracked, patch: testsPatch)
        b.root = worktree
        b.agentID = ada
        var c = file("README.md", .modified, stage: .staged, patch: readmePatch)
        c.agentID = bo
        let result = ReviewResult(files: [a, b, c], isGit: true, comparison: "Compared with the folder before the first turn, and each worktree with its base branch")
        let model = ReviewModel.preview(target: target, result: result, lineCounts: [a.id: 64])
        model.collapsed = [b.id, c.id]
        return model
    }

    static func file(_ path: String, _ kind: ReviewChangeKind, stage: ReviewStageState, patch: String, oldPath: String? = nil) -> ReviewFileDiff {
        let stats = Format.diffStats(patch)
        return ReviewFileDiff(root: root, path: path, oldPath: oldPath, kind: kind, additions: stats.additions, deletions: stats.deletions,
                              patch: patch, stage: stage)
    }

    static let diffViewPatch = """
    diff --git a/Packages/EnsembleKit/Sources/EnsembleKit/UI/DiffView.swift b/Packages/EnsembleKit/Sources/EnsembleKit/UI/DiffView.swift
    index 3f2a1b0..8c9d4e2 100644
    --- a/Packages/EnsembleKit/Sources/EnsembleKit/UI/DiffView.swift
    +++ b/Packages/EnsembleKit/Sources/EnsembleKit/UI/DiffView.swift
    @@ -58,8 +58,11 @@ public enum DiffParser {
     /// Coloured unified diff with line numbers.
     public struct DiffView: View {
    -    let lines: [DiffLine]
    -    var maxLines: Int?
    +    let parsed: ParsedDiff
    +    let options: DiffDisplayOptions
    +    let interaction: DiffInteraction
         @Environment(\\.theme) private var theme
    -    @State private var showAll = false
    +    @State private var showAll = true
    +    @State private var expandedGaps: Set<Int> = []
    +    @State private var newText: [String]?

         public init(diff: String, maxLines: Int? = 40) {
    @@ -112,5 +115,6 @@ public struct DiffView: View {
                 Text(line.text.isEmpty ? " " : line.text)
                     .foregroundStyle(theme.textPrimary)
    -                .fixedSize(horizontal: true, vertical: false)
    +                .fixedSize(horizontal: false, vertical: true)
    +                .frame(maxWidth: .infinity, alignment: .leading)
                     .padding(.trailing, theme.z(12))
             }

    """

    static let newFilePatch = """
    diff --git a/Apps/Mac/Review/ReviewPane.swift b/Apps/Mac/Review/ReviewPane.swift
    new file mode 100644
    --- /dev/null
    +++ b/Apps/Mac/Review/ReviewPane.swift
    @@ -0,0 +1,8 @@
    +import SwiftUI
    +import EnsembleKit
    +
    +/// Every file the session changed, with its diff.
    +struct ReviewPane: View {
    +    @Bindable var model: ReviewModel
    +    var onClose: (() -> Void)?
    +}

    """

    static let mainViewPatch = """
    diff --git a/Apps/Mac/Main/MainView.swift b/Apps/Mac/Main/MainView.swift
    --- a/Apps/Mac/Main/MainView.swift
    +++ b/Apps/Mac/Main/MainView.swift
    @@ -52,4 +52,7 @@ struct MainView: View {
                 CenterColumn(store: store, window: window)
                     .frame(maxWidth: .infinity, maxHeight: .infinity)
    +            if window.sidePane == .review, let session = store.selected {
    +                ReviewPane(store: store, session: session)
    +            }
                 if showsPanel {

    """

    static let progressPatch = """
    diff --git a/docs/PROGRESS.md b/docs/PROGRESS.md
    --- a/docs/PROGRESS.md
    +++ b/docs/PROGRESS.md
    @@ -3,3 +3,4 @@
     Newest first. One line per finished piece; details in commits.

    +- Review pane: session and room diffs, line comments to the agent, stage and commit.
     ## 2026-11-17

    """

    static let deletedPatch = """
    diff --git a/Apps/Mac/Placeholders/ReviewPlaceholder.swift b/Apps/Mac/Placeholders/ReviewPlaceholder.swift
    deleted file mode 100644
    --- a/Apps/Mac/Placeholders/ReviewPlaceholder.swift
    +++ /dev/null
    @@ -1,4 +0,0 @@
    -import SwiftUI
    -
    -/// Placeholder until the review pane exists.
    -struct ReviewPlaceholder: View { var body: some View { Text("Review") } }

    """

    static let renamePatch = """
    diff --git a/Packages/EnsembleKit/Sources/EnsembleKit/Rooms/GitRunner.swift b/Packages/EnsembleKit/Sources/EnsembleKit/Store/GitRunner.swift
    similarity index 100%
    rename from Packages/EnsembleKit/Sources/EnsembleKit/Rooms/GitRunner.swift
    rename to Packages/EnsembleKit/Sources/EnsembleKit/Store/GitRunner.swift

    """

    static let parserPatch = """
    diff --git a/Sources/Parser.swift b/Sources/Parser.swift
    --- a/Sources/Parser.swift
    +++ b/Sources/Parser.swift
    @@ -12,6 +12,7 @@ struct Parser {
         func parse(_ text: String) -> [Token] {
    -        let words = text.split(separator: " ")
    +        let words = text.split(whereSeparator: \\.isWhitespace)
    +        guard !words.isEmpty else { return [] }
             return words.map { Token(String($0)) }
         }


    """

    static let testsPatch = """
    diff --git a/Sources/Parser+Tests.swift b/Sources/Parser+Tests.swift
    new file mode 100644
    --- /dev/null
    +++ b/Sources/Parser+Tests.swift
    @@ -0,0 +1,3 @@
    +import Testing
    +
    +@Test func emptyTextHasNoTokens() { #expect(Parser().parse("").isEmpty) }

    """

    static let readmePatch = """
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,3 @@
     # Parser

    -Splits text on spaces.
    +Splits text on any whitespace.

    """

    // MARK: Rendering

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, height: CGFloat?, zoom: CGFloat,
                                      scheme: ColorScheme, @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let h = height.map { $0 * zoom }
        let content = Canvas(width: w, height: h) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: h)
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
        let height: CGFloat?
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, height: height, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: height == nil)
                .background(theme.background)
        }
    }
}
