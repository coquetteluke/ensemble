import Foundation
import Testing
@testable import EnsembleKit

/// Formatting, Markdown and diff parsing used by the shared views.
@Suite struct StoreFormattingTests {
    @Test func tokenCountsMatchThePanel() {
        #expect(Format.tokens(463) == "463")
        #expect(Format.tokens(10_000) == "10k")
        #expect(Format.tokens(19_200) == "19.2k")
        #expect(Format.tokens(466_900) == "466.9k")
        #expect(Format.tokens(999_990) == "1M")
        #expect(Format.tokens(1_000_000) == "1M")
        #expect(Format.tokens(1_250_000) == "1.3M")
    }

    @Test func percentages() {
        #expect(Format.percent(403_300, of: 1_000_000) == "40.3%")
        #expect(Format.percent(357, of: 1_000_000) == "0.0%")
        #expect(Format.wholePercent(0.4669) == "47%")
        #expect(Format.usd(2.844) == "$2.84")
        #expect(Format.usd(0.001) == "<$0.01")
    }

    @Test func relativeTimes() {
        let now = Date()
        #expect(Format.relative(now.addingTimeInterval(-20), now: now) == "now")
        #expect(Format.relative(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(Format.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
        #expect(Format.relative(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
    }

    @Test func paths() {
        let home = NSHomeDirectory()
        #expect(Format.parentPath(home + "/Ensemble") == "~")
        #expect(Format.folderName(home + "/Developer/site") == "site")
        #expect(Format.parentPath(home + "/Developer/site") == "~/Developer")
        #expect(Format.relativePath("/p/Sources/App.swift", base: "/p") == "Sources/App.swift")
    }

    @Test func markdownBlocks() {
        let blocks = MarkdownParser.parse("""
        # Title

        Some **bold** text
        on two lines.

        - one
        - two
          continued
        1. first

        ```swift
        let x = 1
        ```

        > quoted

        ---

        | A | B |
        |---|---|
        | 1 | 2 |
        """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\non two lines."),
            .list([
                MarkdownListItem(marker: "\u{2022}", text: "one", indent: 0, checked: nil),
                MarkdownListItem(marker: "\u{2022}", text: "two continued", indent: 0, checked: nil),
                MarkdownListItem(marker: "1.", text: "first", indent: 0, checked: nil),
            ]),
            .code(language: "swift", code: "let x = 1"),
            .quote("quoted"),
            .rule,
            .table(header: ["A", "B"], rows: [["1", "2"]]),
        ])
    }

    @Test func unclosedFenceRunsToTheEndWhileStreaming() {
        let blocks = MarkdownParser.parse("Here:\n```py\nprint(1)\nprint(2)")
        #expect(blocks == [.paragraph("Here:"), .code(language: "py", code: "print(1)\nprint(2)")])
    }

    @Test func diffParsingNumbersLines() {
        let lines = DiffParser.parse("""
        --- a/f.swift
        +++ b/f.swift
        @@ -10,3 +10,3 @@
         keep
        -old
        +new
        """)
        #expect(lines.map(\.kind) == [.hunk, .context, .deletion, .addition])
        #expect(lines[1].oldNumber == 10 && lines[1].newNumber == 10)
        #expect(lines[2].oldNumber == 11)
        #expect(lines[3].newNumber == 11)
        let stats = Format.diffStats("+a\n+b\n-c\n+++ x\n--- y")
        #expect(stats.additions == 2 && stats.deletions == 1)
    }

    @Test func toolSummaries() {
        let edit = ToolSummary(ToolCallInfo(id: "1", name: "edit", title: "/p/Sources/App.swift", status: .succeeded,
                                            diff: "@@ -1 +1 @@\n-a\n+b\n+c"), baseDirectory: "/p")
        #expect(edit.verb == "Edited")
        #expect(edit.subject == "Sources/App.swift")
        #expect(edit.additions == 2 && edit.deletions == 1)
        let bash = ToolSummary(ToolCallInfo(id: "2", name: "bash", title: "npm test", status: .running))
        #expect(bash.verb == "Running")
        #expect(bash.monospacedSubject)
    }

    @Test func permissionModeCyclesThroughAllFour() {
        #expect(PermissionMode.ask.next == .acceptEdits)
        #expect(PermissionMode.bypass.next == .ask)
        #expect(PermissionMode.bypass.isDangerous)
    }
}
