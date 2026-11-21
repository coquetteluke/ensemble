import Foundation
import Testing
@testable import EnsembleKit

@Suite struct NextStepTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func user(_ id: String = "u1", _ text: String = "Fix it") -> TranscriptItem {
        .user(id: id, text: text, date: now)
    }

    private func agent(_ text: String, id: String = "a1") -> TranscriptItem {
        .agentText(id: id, text: text, agentID: nil, streaming: false)
    }

    private func tool(_ name: String, _ title: String, id: String = UUID().uuidString, status: ToolStatus = .succeeded,
                      diff: String? = nil) -> TranscriptItem {
        .tool(ToolCallInfo(id: id, name: name, title: title, status: status, diff: diff))
    }

    private let diff = """
    --- a/Sources/ContextBar.swift
    +++ b/Sources/ContextBar.swift
    @@ -1,3 +1,4 @@
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
    """

    @Test func aTurnThatChangedFilesOffersTheReview() throws {
        let items = [user(), tool("edit", "Sources/ContextBar.swift", diff: diff), tool("bash", "swift test"),
                     agent("Done. The bar now sizes by the limit.")]
        let step = try #require(NextStepBuilder.build(items: items, isWorking: false, hasOpenPrompt: false))
        #expect(step.turnID == "u1")
        #expect(step.actions == [.reviewChanges])
        #expect(step.question == nil)
        #expect(step.work == NextStep.Work(filesChanged: 1, additions: 2, deletions: 1, commands: 1, failedSteps: 0,
                                           firstFile: "ContextBar.swift"))
        #expect(step.recap == "Changed ContextBar.swift (+2, -1). Ran a command.")
    }

    @Test func aYesOrNoQuestionGetsBothRepliesFirst() throws {
        let items = [user(), tool("write", "README.md"), agent("I wrote the README.\n\nShould I commit it?")]
        let step = try #require(NextStepBuilder.build(items: items, isWorking: false, hasOpenPrompt: false))
        #expect(step.question == "Should I commit it?")
        #expect(step.actions == [.replyYes, .replyNo, .reviewChanges])
        #expect(step.actions.first?.reply == "Yes")
    }

    @Test func aQuestionAloneStillGetsRepliesWhenYesOrNoAnswersIt() throws {
        let items = [user(), agent("Nothing changed yet. Want me to run the tests first?")]
        let step = try #require(NextStepBuilder.build(items: items, isWorking: false, hasOpenPrompt: false))
        #expect(step.question == "Want me to run the tests first?")
        #expect(step.actions == [.replyYes, .replyNo])
        #expect(step.recap.isEmpty)
    }

    @Test func noCardWhileWorkingOrWhileAPromptWaits() {
        let items = [user(), tool("edit", "a.swift"), agent("Done.")]
        #expect(NextStepBuilder.build(items: items, isWorking: true, hasOpenPrompt: false) == nil)
        #expect(NextStepBuilder.build(items: items, isWorking: false, hasOpenPrompt: true) == nil)
    }

    @Test func noCardForAPlainAnswerAnOpenQuestionOrAFailedTurn() {
        #expect(NextStepBuilder.build(items: [user(), agent("It is a struct.")], isWorking: false, hasOpenPrompt: false) == nil)
        #expect(NextStepBuilder.build(items: [user(), agent("Which file do you mean?")], isWorking: false, hasOpenPrompt: false) == nil)
        #expect(NextStepBuilder.build(items: [user(), tool("bash", "ls"), agent("Listed.")], isWorking: false, hasOpenPrompt: false) == nil)
        let failed: [TranscriptItem] = [user(), tool("edit", "a.swift"), .error(id: "e", message: "Model unavailable")]
        #expect(NextStepBuilder.build(items: failed, isWorking: false, hasOpenPrompt: false) == nil)
        #expect(NextStepBuilder.build(items: [], isWorking: false, hasOpenPrompt: false) == nil)
        #expect(NextStepBuilder.build(items: [user()], isWorking: false, hasOpenPrompt: false) == nil)
    }

    @Test func onlyTheNewestTurnCounts() throws {
        let items = [user("u1"), tool("edit", "old.swift"), agent("Done.", id: "a1"),
                     user("u2", "And now?"), tool("edit", "new.swift"), tool("edit", "new.swift"), tool("write", "more.swift"),
                     agent("Both updated.", id: "a2")]
        let step = try #require(NextStepBuilder.build(items: items, isWorking: false, hasOpenPrompt: false))
        #expect(step.turnID == "u2")
        #expect(step.work.filesChanged == 2)
        #expect(step.work.firstFile == "new.swift")
        #expect(step.recap == "Changed new.swift and 1 more file.")
    }

    @Test func failedStepsAreCountedAndAFailedEditChangesNothing() throws {
        let items = [user(), tool("edit", "a.swift", status: .failed), tool("edit", "b.swift"), tool("edit", "c.swift"),
                     tool("edit", "d.swift"), tool("bash", "make", status: .failed), tool("bash", "make"), agent("Built.")]
        let step = try #require(NextStepBuilder.build(items: items, isWorking: false, hasOpenPrompt: false))
        #expect(step.work.filesChanged == 3)
        #expect(step.work.failedSteps == 2)
        #expect(step.recap == "Changed b.swift and 2 more files. Ran 2 commands, 2 steps failed.")
    }

    @Test func theClosingQuestionIsOnePlainLine() {
        #expect(NextStepBuilder.closingQuestion("All green.\n\n**Should I open a pull request?**") == "Should I open a pull request?")
        #expect(NextStepBuilder.closingQuestion("- Want me to `push` it?") == "Want me to push it?")
        #expect(NextStepBuilder.closingQuestion("Done.") == nil)
        #expect(NextStepBuilder.closingQuestion("Is it right?\nYes, it is.") == nil)
        let long = String(repeating: "The suite ran clean on every target. ", count: 6) + "Should I merge it now?"
        #expect(NextStepBuilder.closingQuestion(long) == "Should I merge it now?")
        #expect(NextStepBuilder.closingQuestion("Nothing changed yet. Want me to run the tests?") == "Want me to run the tests?")
        #expect(NextStepBuilder.closingQuestion("I wrote README.md, want me to commit v2.3 too?") == "I wrote README.md, want me to commit v2.3 too?")
    }

    @Test func yesOrNoIsToldFromAChoiceOrAnOpenQuestion() {
        #expect(NextStepBuilder.isYesOrNo("Should I go ahead?"))
        #expect(NextStepBuilder.isYesOrNo("The tests pass, want me to commit?"))
        #expect(NextStepBuilder.isYesOrNo("Push now, yes or no?"))
        #expect(NextStepBuilder.isYesOrNo("Do you want the long version?"))
        #expect(!NextStepBuilder.isYesOrNo("Should I use SQLite or Postgres?"))
        #expect(!NextStepBuilder.isYesOrNo("Which file do you mean?"))
        #expect(!NextStepBuilder.isYesOrNo("What should the title be?"))
        #expect(!NextStepBuilder.isYesOrNo("How should I name it?"))
    }

    @Test func diffCountsLeaveOutTheFileLines() {
        let counts = NextStepBuilder.diffCounts(diff)
        #expect(counts.additions == 2)
        #expect(counts.deletions == 1)
        #expect(NextStepBuilder.diffCounts(nil).additions == 0)
    }
}
