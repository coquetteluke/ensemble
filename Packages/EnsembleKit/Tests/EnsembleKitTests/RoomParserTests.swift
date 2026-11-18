import Testing
@testable import EnsembleKit

@Suite struct RoomParserTests {
    let parser = RoomReplyParser(agentNames: ["Alpha", "Beta", "Gamma", "Code Llama"])

    // MARK: DONE

    @Test(arguments: [
        "DONE",
        "done",
        "**DONE**",
        "- DONE",
        "* **Done.**",
        "Done.",
        "Done!",
        "DONE: wrote the parser and its tests",
        "DONE - all tests pass",
        "DONE all tests pass",
        "\u{2705} DONE",
        "`DONE`",
        "Status: DONE",
        "**Status:** done.",
        "1. DONE",
        "## DONE",
        "All tests pass. **DONE**",
        "Wrote Calc.swift.\n\nDONE",
    ])
    func doneVariantsCount(_ text: String) {
        #expect(parser.parse(text).done, "\(text)")
    }

    @Test(arguments: [
        "Done with step one, now the tests.",
        "I'm done.",
        "Not done yet.",
        "The work is almost done",
        "```\nDONE\n```",
        "> DONE",
        "Donee",
        "Done, but the tests still fail.",
    ])
    func doneLookalikesDoNotCount(_ text: String) {
        #expect(!parser.parse(text).done, "\(text)")
    }

    // MARK: Reviews

    @Test(arguments: [
        "APPROVE",
        "Approved.",
        "**APPROVE**",
        "Review: APPROVE",
        "**Decision:** Approve",
        "LGTM, nice work. APPROVE",
        "Looks great \u{2014} all tests pass.\n\n\u{2705} **APPROVED**",
        "VERDICT: APPROVE",
    ])
    func approveVariants(_ text: String) {
        let reply = parser.parse(text)
        #expect(reply.reviewVerdict == .approve, "\(text)")
    }

    @Test func changesTakeTheRestOfTheLine() {
        let reply = parser.parse("CHANGES: rename `foo` to `bar`")
        #expect(reply.reviewVerdict == .changes("rename `foo` to `bar`"))
    }

    @Test func changesTakeFollowingBullets() {
        let reply = parser.parse("Thanks.\n\nCHANGES:\n- rename foo\n- add a test for empty input\n")
        #expect(reply.changes == "- rename foo\n- add a test for empty input")
    }

    @Test func changesVariants() {
        #expect(parser.parse("Changes requested: handle nil").changes == "handle nil")
        #expect(parser.parse("**CHANGES:** handle nil").changes == "handle nil")
        #expect(parser.parse("Request changes - handle nil").changes == "handle nil")
    }

    @Test func messyModelReviewWithLabelAndNumberedList() {
        let text = """
        Thanks for the update! I reviewed `parser.swift` and the tests.

        **Review: CHANGES**

        1. The tokenizer drops trailing whitespace.
        2. Add a test for empty input.

        Otherwise nice work.
        """
        let reply = parser.parse(text)
        guard case .changes(let what)? = reply.reviewVerdict else {
            Issue.record("expected CHANGES, got \(String(describing: reply.reviewVerdict))")
            return
        }
        #expect(what.contains("1. The tokenizer drops trailing whitespace."))
        #expect(what.contains("2. Add a test for empty input."))
    }

    @Test func changesNoneMeansApprove() {
        let reply = parser.parse("APPROVE\n\nChanges: none")
        #expect(reply.changes == nil)
        #expect(reply.reviewVerdict == .approve)
    }

    @Test func changesWinOverApprove() {
        let reply = parser.parse("APPROVE once this is fixed.\nCHANGES: add docs")
        #expect(reply.reviewVerdict == .changes("add docs"))
    }

    @Test func workerSummaryOfChangesIsNotAReview() {
        let reply = parser.parse("Changes I made:\n- added Calc.add\n- wrote tests")
        #expect(reply.changes == nil)
        #expect(reply.reviewVerdict == nil)
    }

    // MARK: Plans

    @Test func messyPlanWithAssignments() {
        let text = """
        Sure! Here's the plan.

        ## Plan:
        Build a calculator with tests.

        **Assignments**
        1. **ASSIGN @Alpha:** write `Calc.swift`
        2. ASSIGN @beta - write CalcTests.swift
           - owns Tests/
        - Assign Gamma: write the README
        * ASSIGN @Zed: something
        """
        let reply = parser.parse(text)
        let plan = try? #require(reply.plan)
        #expect(plan?.contains("Build a calculator with tests.") == true)
        #expect(plan?.contains("ASSIGN @Alpha") == true)
        #expect(reply.assignments == [
            ParsedAssignment(name: "Alpha", task: "write `Calc.swift`"),
            ParsedAssignment(name: "Beta", task: "write CalcTests.swift\n- owns Tests/"),
            ParsedAssignment(name: "Gamma", task: "write the README"),
            ParsedAssignment(name: "Zed", task: "something"),
        ])
    }

    @Test func planOnSameLine() {
        let reply = parser.parse("PLAN: one file hello.txt\nASSIGN @Alpha: write it")
        #expect(reply.plan == "one file hello.txt\nASSIGN @Alpha: write it")
        #expect(reply.assignments == [ParsedAssignment(name: "Alpha", task: "write it")])
    }

    @Test func assignmentHeaderAndProseAreNotKeywords() {
        let reply = parser.parse("Assignments:\nThe plan is to approve changes later.\nPlanning takes time.")
        #expect(reply.assignments.isEmpty)
        #expect(reply.plan == nil)
        #expect(!reply.approve)
        #expect(reply.changes == nil)
    }

    @Test func multiWordNames() {
        let reply = parser.parse("ASSIGN @Code Llama: port the CLI\n@code llama: ping me when done?")
        #expect(reply.assignments == [ParsedAssignment(name: "Code Llama", task: "port the CLI")])
        #expect(reply.addressed == [AddressedMessage(names: ["Code Llama"], toAll: false, text: "ping me when done?")])
    }

    // MARK: Addressing

    @Test func addressedBlocks() {
        let text = """
        I finished the parser.
        @Beta: can you check the tokenizer?
        It is in Lexer.swift.

        @all heads up: main is green.
        **@Gamma**, @beta please review.
        @MainActor is not a person.
        DONE
        """
        let reply = parser.parse(text)
        #expect(reply.addressed == [
            AddressedMessage(names: ["Beta"], toAll: false, text: "can you check the tokenizer?\nIt is in Lexer.swift."),
            AddressedMessage(names: [], toAll: true, text: "heads up: main is green."),
            AddressedMessage(names: ["Gamma", "Beta"], toAll: false, text: "please review."),
        ])
        #expect(reply.done)
        #expect(reply.boardText.contains("I finished the parser."))
        #expect(reply.boardText.contains("@MainActor is not a person."))
        #expect(!reply.boardText.contains("tokenizer"))
    }

    @Test func addressBlockStopsAtKeyword() {
        let reply = parser.parse("- @Alpha: should add() wrap on overflow?\nDONE")
        #expect(reply.addressed == [AddressedMessage(names: ["Alpha"], toAll: false, text: "should add() wrap on overflow?")])
        #expect(reply.done)
    }

    @Test func emailsAndMidLineMentionsAreNotAddresses() {
        let reply = parser.parse("Mail me at dev@example.com.\nAsk @Beta later.")
        #expect(reply.addressed.isEmpty)
    }

    @Test func leadingAddressForUserMessages() {
        #expect(parser.leadingAddress("@Beta what do you think?") == AddressedMessage(names: ["Beta"], toAll: false, text: "what do you think?"))
        #expect(parser.leadingAddress("@all ship it") == AddressedMessage(names: [], toAll: true, text: "ship it"))
        #expect(parser.leadingAddress("@Alpha @Gamma: sync up\nsecond line") == AddressedMessage(names: ["Alpha", "Gamma"], toAll: false, text: "sync up\nsecond line"))
        #expect(parser.leadingAddress("hello @Beta") == nil)
        #expect(parser.leadingAddress("@Nobody hi") == nil)
    }

    // MARK: Round table and debate words

    @Test(arguments: ["AGREE", "I agree.", "Agreed!", "**AGREE** with the plan", "- agree"])
    func agreeVariants(_ text: String) {
        #expect(parser.parse(text).agree, "\(text)")
    }

    @Test(arguments: ["I agree with most of it, but the cache is wrong.", "Agreement matters.", "We could agree later"])
    func agreeLookalikes(_ text: String) {
        #expect(!parser.parse(text).agree, "\(text)")
    }

    @Test(arguments: ["TAKEOVER", "TAKEOVER: I can finish this faster", "Take over.", "**TAKE OVER**"])
    func takeoverVariants(_ text: String) {
        #expect(parser.parse(text).takeover, "\(text)")
    }

    @Test func takeoverLookalike() {
        #expect(!parser.parse("Takeover would be overkill here.").takeover)
    }

    @Test func verdictVariants() {
        #expect(parser.parse("**VERDICT:** Use SQLite.\nReasons: local, simple.").verdict == "Use SQLite.\nReasons: local, simple.")
        #expect(parser.parse("Final verdict: Postgres").verdict == "Postgres")
        #expect(parser.parse("After weighing it all:\n\n## Verdict\nUse SQLite").verdict == "Use SQLite")
        #expect(parser.parse("My verdict is SQLite").verdict == nil)
    }

    // MARK: Misc

    @Test func windowsLineEndings() {
        let reply = parser.parse("PLAN: x\r\nASSIGN @Beta: y\r\nDONE\r\n")
        #expect(reply.assignments == [ParsedAssignment(name: "Beta", task: "y")])
        #expect(reply.done)
    }

    @Test func keywordsInCodeFencesAreIgnored() {
        let text = """
        Here is the script:
        ```bash
        echo DONE
        APPROVE
        @Beta: not a message
        ```
        Still working on it.
        """
        let reply = parser.parse(text)
        #expect(!reply.done)
        #expect(!reply.approve)
        #expect(reply.addressed.isEmpty)
        #expect(reply.boardText.contains("echo DONE"))
    }

    @Test func parserWithoutRosterAcceptsAnyName() {
        let bare = RoomReplyParser()
        let reply = bare.parse("ASSIGN @Delta: tests\n@Delta: hi")
        #expect(reply.assignments == [ParsedAssignment(name: "Delta", task: "tests")])
        #expect(reply.addressed.first?.names == ["Delta"])
    }

    @Test func rosterNameNormalizesSpelling() {
        #expect(parser.rosterName(for: "@beta:") == "Beta")
        #expect(parser.rosterName(for: "**GAMMA**") == "Gamma")
        #expect(parser.rosterName(for: "Zed") == nil)
    }
}
