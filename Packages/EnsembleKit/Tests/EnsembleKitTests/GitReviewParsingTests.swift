import Foundation
import Testing
@testable import EnsembleKit

/// Parsers, word diffs, comment messages and commit message cleanup for the review pane (no git needed).
@Suite struct GitReviewParsingTests {
    @Test func numstatReadsRenamesAndBinaryFiles() {
        let raw = "3\t1\tSources/a b.swift\u{0}-\t-\timage.png\u{0}0\t0\t\u{0}old name.txt\u{0}dossier é/new name.txt\u{0}"
        let entries = GitDiffParsing.numstat(Data(raw.utf8))
        #expect(entries.count == 3)
        #expect(entries[0].path == "Sources/a b.swift" && entries[0].additions == 3 && entries[0].deletions == 1)
        #expect(entries[1].isBinary && entries[1].path == "image.png")
        #expect(entries[2].path == "dossier é/new name.txt" && entries[2].oldPath == "old name.txt")
    }

    @Test func statusV2ReadsEveryKindOfEntry() {
        let raw = [
            "1 M. N... 100644 100644 100644 abc abc staged.txt",
            "1 MM N... 100644 100644 100644 abc abc both ways.txt",
            "1 .M N... 100644 100644 100644 abc abc naïve file.txt",
            "2 R. N... 100644 100644 100644 abc abc R100 renamed.txt",
            "old.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? new folder/untracked.txt",
        ].joined(separator: "\u{0}") + "\u{0}"
        let status = GitDiffParsing.status(Data(raw.utf8))
        #expect(status["staged.txt"]?.state == .staged)
        #expect(status["both ways.txt"]?.state == .partial)
        #expect(status["naïve file.txt"]?.state == .unstaged)
        #expect(status["renamed.txt"]?.state == .staged)
        #expect(status["old.txt"] == nil)
        #expect(status["conflict.txt"]?.state == .conflicted)
        #expect(status["new folder/untracked.txt"]?.state == .untracked)
    }

    @Test func hunksAndChunksSplitCleanly() {
        let patch = """
        diff --git a/one.txt b/one.txt
        index 1..2 100644
        --- a/one.txt
        +++ b/one.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        @@ -10 +10,2 @@ func x
         ten
        +eleven
        diff --git a/two.txt b/two.txt
        new file mode 100644
        --- /dev/null
        +++ b/two.txt
        @@ -0,0 +1 @@
        +hello
        \\ No newline at end of file

        """
        let chunks = GitDiffParsing.fileChunks(patch)
        #expect(chunks.count == 2)
        #expect(GitDiffParsing.changeKind(chunks[0]) == .modified)
        #expect(GitDiffParsing.changeKind(chunks[1]) == .added)
        #expect(GitDiffParsing.chunkPath(chunks[1]) == "two.txt")
        let hunks = GitDiffParsing.hunks(in: chunks[0])
        #expect(hunks.count == 2)
        #expect(hunks[1].oldStart == 10 && hunks[1].oldCount == 1 && hunks[1].newStart == 10 && hunks[1].newCount == 2)
        #expect(hunks[0].lines == [" keep", "-old", "+new"])
        #expect(GitDiffParsing.hunks(in: chunks[1]).first?.lines.last == "\\ No newline at end of file")
        #expect(GitDiffParsing.fileHeader(chunks[0]).hasSuffix("+++ b/one.txt\n"))
    }

    @Test func quotedPathsAreUnquoted() {
        #expect(GitDiffParsing.unquote("\"tab\\there\"") == "tab\there")
        #expect(GitDiffParsing.unquote("\"caf\\303\\251.txt\"") == "café.txt")
        #expect(GitDiffParsing.unquote("plain name.txt") == "plain name.txt")
    }

    @Test func hunkActionsMatchOnlyIdenticalIndexHunks() {
        let session = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        @@ -20,3 +20,3 @@
         x
        -y
        +Y
         z

        """
        // The first hunk is staged already (old side matches HEAD), the second is still in the work tree.
        let unstaged = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -20,3 +20,3 @@
         x
        -y
        +Y
         z

        """
        let staged = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c

        """
        let actions = GitDiffParsing.hunkActions(session: session, unstaged: unstaged, staged: staged)
        #expect(actions[0]?.kind == .unstage)
        #expect(actions[1]?.kind == .stage)
        #expect(actions[1]?.patch.hasPrefix("diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -20,3 +20,3 @@") == true)
        // A new file never gets hunk buttons.
        let newFile = "diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+x\n"
        #expect(GitDiffParsing.hunkActions(session: newFile, unstaged: newFile, staged: nil).isEmpty)
    }

    @Test func wordDiffHighlightsOnlyTheChangedWords() throws {
        let changes = try #require(WordDiff.changedRanges(old: "let total = price * count", new: "let total = price * quantity"))
        #expect(changes.old == [20..<25])
        #expect(changes.new == [20..<28])
        // Lines with little in common are left whole.
        #expect(WordDiff.changedRanges(old: "import Foundation", new: "return value + 1") == nil)
        let parsed = ParsedDiff("@@ -1 +1 @@\n-let a = 1\n+let a = 2\n")
        #expect(parsed.wordChanges[1] == [8..<9])
        #expect(parsed.wordChanges[2] == [8..<9])
    }

    @Test func gapsCoverUnchangedLinesBetweenHunks() {
        let parsed = ParsedDiff("""
        @@ -5,3 +5,4 @@
         e
        +new
         f
         g
        @@ -20,2 +21,2 @@
        -t
        +T
         u
        """, wordHighlight: false)
        let rows = parsed.rows(showGaps: true, newLineCount: 30)
        #expect(rows.first == .gap(id: 0, start: 1, count: 4, oldOffset: 0))
        #expect(rows.contains(.gap(id: 1, start: 9, count: 12, oldOffset: -1)))
        #expect(rows.last == .gap(id: 2, start: 23, count: 8, oldOffset: -1))
        // Opening a gap draws its lines with both numbers.
        let text = (1...30).map { "line \($0)" }
        let opened = parsed.rows(showGaps: true, newLineCount: 30, expanded: [1], newText: text)
        #expect(opened.contains(.gapLine(newNumber: 9, oldNumber: 8, text: "line 9")))
        #expect(!opened.contains { if case .gap(1, _, _, _) = $0 { true } else { false } })
        // Without gaps the old layout is unchanged.
        #expect(parsed.rows(showGaps: false).count == parsed.lines.count)
    }

    @Test func commentsBecomeOneClearMessage() {
        let comments = [
            ReviewComment(fileID: "r\u{0}b.swift", path: "Sources/b.swift", line: 7, side: .old, quoted: "oldCall()", text: "Why was this removed?"),
            ReviewComment(fileID: "r\u{0}a.swift", path: "Sources/a.swift", line: 42, side: .new, quoted: "    let x = compute()", text: "  Rename this.\nIt is unclear.  "),
            ReviewComment(fileID: "r\u{0}a.swift", path: "Sources/a.swift", line: 3, side: .new, quoted: "", text: "Remove the blank line."),
        ]
        let message = ReviewCommentFormatter.message(comments)
        #expect(message == """
        Review comments on your changes (3). Please address each one:

        1. Sources/a.swift, line 3:
        > (empty line)

        Remove the blank line.

        2. Sources/a.swift, line 42:
        >     let x = compute()

        Rename this.
        It is unclear.

        3. Sources/b.swift, line 7 (a removed line):
        > oldCall()

        Why was this removed?
        """)
    }

    @Test func roomCommentsAreSplitByAgent() {
        let ada = UUID()
        let bo = UUID()
        let comments = [
            ReviewComment(fileID: "1", path: "a.txt", line: 1, side: .new, quoted: "a", text: "one", agentID: ada, created: Date(timeIntervalSince1970: 1)),
            ReviewComment(fileID: "2", path: "b.txt", line: 2, side: .new, quoted: "b", text: "two", agentID: bo, created: Date(timeIntervalSince1970: 2)),
            ReviewComment(fileID: "3", path: "c.txt", line: 3, side: .new, quoted: "c", text: "three", agentID: ada, created: Date(timeIntervalSince1970: 3)),
        ]
        let messages = ReviewCommentFormatter.messagesByAgent(comments)
        #expect(messages.map(\.agentID) == [ada, bo])
        #expect(messages[0].text.contains("(2)") && messages[0].text.contains("c.txt") && !messages[0].text.contains("b.txt"))
    }

    @Test func commitMessagesAreCleanedUp() {
        #expect(GitCommitMessage.clean("Add the review pane.") == "Add the review pane")
        #expect(GitCommitMessage.clean("```\nCommit message: \"Fix the diff gutter\"\n```") == "Fix the diff gutter")
        #expect(GitCommitMessage.clean("\n\n`Stage hunks on their own`\nThis lets you...") == "Stage hunks on their own")
        #expect(GitCommitMessage.clean("Review pane \u{2014} comments and commits") == "Review pane, comments and commits")
        #expect(GitCommitMessage.clean("  \n ") == nil)
    }

    @Test func commitPromptListsFilesAndCutsLongDiffs() {
        let files = [
            ReviewFileDiff(root: "/r", path: "a.swift", kind: .modified, additions: 2, deletions: 1, patch: String(repeating: "+x\n", count: 10)),
            ReviewFileDiff(root: "/r", path: "logo.png", kind: .added, isBinary: true),
            ReviewFileDiff(root: "/r", path: "new.swift", oldPath: "old.swift", kind: .renamed),
        ]
        let prompt = GitCommitMessage.prompt(files: files, diffLimit: 12)
        #expect(prompt.contains("M a.swift (+2 -1)"))
        #expect(prompt.contains("A logo.png (binary)"))
        #expect(prompt.contains("R old.swift -> new.swift"))
        #expect(prompt.contains("[diff cut short]"))
        #expect(!prompt.contains("\u{2014}"))
    }

    @Test func lastTurnEditsComeFromToolDiffsAfterTheLastMessage() {
        let items: [TranscriptItem] = [
            .user(id: "u1", text: "first", date: Date()),
            .tool(ToolCallInfo(id: "t1", name: "edit", title: "old.swift", inputJSON: #"{"file_path":"/p/old.swift"}"#, status: .succeeded, diff: "@@ -1 +1 @@\n-a\n+b\n")),
            .user(id: "u2", text: "second", date: Date()),
            .tool(ToolCallInfo(id: "t2", name: "edit", title: "x", inputJSON: #"{"file_path":"/p/Sources/a.swift"}"#, status: .succeeded, diff: "@@ -1 +1 @@\n-a\n+b\n")),
            .tool(ToolCallInfo(id: "t3", name: "write", title: "x", inputJSON: #"{"filePath":"/p/new.txt"}"#, status: .succeeded, diff: "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hi\n")),
            .tool(ToolCallInfo(id: "t4", name: "edit", title: "x", inputJSON: #"{"file_path":"/p/Sources/a.swift"}"#, status: .succeeded, diff: "@@ -5 +5 @@\n-c\n+d\n")),
            .tool(ToolCallInfo(id: "t5", name: "bash", title: "ls", status: .succeeded)),
        ]
        let files = ReviewEngineDiffs.lastTurnFiles(items, root: "/p")
        #expect(files.map(\.path) == ["Sources/a.swift", "new.txt"])
        #expect(files[0].additions == 2 && files[0].deletions == 2 && files[0].hunks.count == 2)
        #expect(files[1].kind == .added)
        #expect(files.allSatisfy { !$0.fromGit && $0.stage == .notGit })
    }
}
