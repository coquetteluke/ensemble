import Foundation
import Testing
@testable import EnsembleKit

/// The task list card is fed by whichever plan or todo tool an engine uses (`TodoParser`).
@Suite("Task list from plan tools")
struct TaskListPlanToolTests {
    static let updatePlan = "mcp__ccd_turn__update_plan"
    static let wrapUp = "mcp__ccd_turn__wrap_up"

    private func tool(_ name: String, _ input: String, status: ToolStatus = .succeeded, output: String? = nil,
                      id: String = UUID().uuidString) -> TranscriptItem {
        .tool(ToolCallInfo(id: id, name: name, title: name, inputJSON: input, status: status, outputPreview: output))
    }

    private func statuses(_ items: [TranscriptItem]) -> [TodoItem.Status]? {
        TodoParser.latest(in: items)?.map(\.status)
    }

    /// The first plan of a real imported session, shortened to its shape.
    static let sevenSteps = """
    {"items": [{"content": "Look at notes", "status": "in_progress"}, {"content": "Work out a toggle", "status": "pending"},
     {"content": "Write the helper", "status": "pending"}, {"content": "Write install and README", "status": "pending"},
     {"content": "Build, sign, install", "status": "pending"}, {"content": "Grant the permission", "status": "pending"},
     {"content": "Verify and report", "status": "pending"}], "scope": "first_task"}
    """

    @Test func updatePlanIsReplayedStepByStep() {
        var items: [TranscriptItem] = [
            .user(id: "u", text: "Build it", date: Date()),
            tool(Self.updatePlan, Self.sevenSteps),
        ]
        #expect(TodoParser.latest(in: items)?.map(\.content).first == "Look at notes")
        #expect(statuses(items) == [.inProgress, .pending, .pending, .pending, .pending, .pending, .pending])

        // The exact follow-up calls of that session.
        items += [tool("Bash", #"{"command": "ls"}"#), tool(Self.updatePlan, #"{"done": [1], "start": 3}"#)]
        #expect(statuses(items) == [.completed, .pending, .inProgress, .pending, .pending, .pending, .pending])

        items.append(tool(Self.updatePlan, #"{"advance": true}"#))
        #expect(statuses(items) == [.completed, .pending, .completed, .inProgress, .pending, .pending, .pending])

        items.append(tool(Self.updatePlan, #"{"done": [4, 5], "start": 6}"#))
        #expect(statuses(items) == [.completed, .pending, .completed, .completed, .completed, .inProgress, .pending])
    }

    @Test func advanceFinishesTheStepInProgressAndStartsTheNextOneToDo() {
        let list = #"{"items": [{"content": "A", "status": "completed"}, {"content": "B", "status": "in_progress"}, {"content": "C", "status": "completed"}, {"content": "D", "status": "pending"}]}"#
        var items = [tool(Self.updatePlan, list), tool(Self.updatePlan, #"{"advance": true}"#)]
        #expect(statuses(items) == [.completed, .completed, .completed, .inProgress], "a finished step is skipped")
        items.append(tool(Self.updatePlan, #"{"advance": true}"#))
        #expect(statuses(items) == [.completed, .completed, .completed, .completed], "the last advance leaves nothing in progress")

        // Nothing in progress: advance starts the first step still to do.
        let fresh = #"{"items": [{"content": "A", "status": "pending"}, {"content": "B", "status": "pending"}]}"#
        #expect(statuses([tool(Self.updatePlan, fresh), tool(Self.updatePlan, #"{"advance": true}"#)]) == [.inProgress, .pending])
    }

    @Test func aNewWholeListReplacesTheOldOne() {
        let items = [
            tool(Self.updatePlan, Self.sevenSteps),
            tool(Self.updatePlan, #"{"advance": true}"#),
            tool(Self.updatePlan, #"{"items": [{"content": "Confirm the switch", "status": "in_progress"}, {"content": "Test Play", "status": "pending"}], "scope": "continuation"}"#),
            tool(Self.updatePlan, #"{"done": [1], "start": 2}"#),
        ]
        let list = TodoParser.latest(in: items)
        #expect(list?.map(\.content) == ["Confirm the switch", "Test Play"])
        #expect(list?.map(\.status) == [.completed, .inProgress])
    }

    @Test func wrapUpChecksOffWhatIsLeft() {
        let items = [
            tool(Self.updatePlan, Self.sevenSteps),
            tool(Self.updatePlan, #"{"done": [1, 2, 3, 4, 5], "start": 6}"#),
            tool(Self.wrapUp, #"{"recap": "All done."}"#),
        ]
        #expect(statuses(items)?.allSatisfy { $0 == .completed } == true)
        // Another server's tool of the same name says nothing about this list.
        let other = [tool(Self.updatePlan, Self.sevenSteps), tool("mcp__notes__wrap_up", "{}")]
        #expect(statuses(other)?.first == .inProgress)
    }

    @Test func aFailedCallChangesNothing() {
        let items = [
            tool(Self.updatePlan, Self.sevenSteps),
            tool(Self.updatePlan, #"{"advance": true}"#, status: .failed),
            tool(Self.updatePlan, #"{"items": [{"content": "Other", "status": "pending"}]}"#, status: .failed),
        ]
        #expect(statuses(items) == [.inProgress, .pending, .pending, .pending, .pending, .pending, .pending])
        // A call still running already counts: the card follows the agent live.
        let live = [tool(Self.updatePlan, Self.sevenSteps, status: .running)]
        #expect(statuses(live)?.count == 7)
    }

    @Test func placesOutOfRangeAndOddValuesAreIgnored() {
        let items = [
            tool(Self.updatePlan, #"{"items": [{"content": "A", "status": "pending"}, {"content": "B", "status": "pending"}]}"#),
            tool(Self.updatePlan, #"{"done": [0, 9, "x", true], "start": 2}"#),
        ]
        #expect(statuses(items) == [.pending, .inProgress], "true is not place 1, and 0 and 9 are not in the list")
        // Places are whole JSON numbers, and 1 must not be mistaken for a boolean.
        #expect(TodoParser.integers([1, 2.0, NSNumber(value: true)]) == [1, 2])
        #expect(TodoParser.identifier(1) == "1")
        #expect(TodoParser.identifier(NSNumber(value: false)) == nil)
    }

    @Test func stepsWithoutAListShowNothing() {
        #expect(TodoParser.latest(in: [tool(Self.updatePlan, #"{"advance": true}"#)]) == nil)
        #expect(TodoParser.latest(in: [tool(Self.wrapUp, "{}")]) == nil)
        #expect(TodoParser.latest(in: [tool("bash", "{}")]) == nil)
        #expect(TodoParser.latest(in: []) == nil)
    }

    @Test func todoWriteStillSendsTheWholeList() {
        let first = #"{"todos": [{"content": "One", "status": "in_progress", "activeForm": "Doing one"}]}"#
        let second = #"{"todos": [{"content": "One", "status": "completed"}, {"content": "Two", "status": "pending"}]}"#
        let items = [tool("todowrite", first), tool("bash", "{}"), tool("TodoWrite", second)]
        #expect(TodoParser.latest(in: items) == [TodoItem(content: "One", status: .completed), TodoItem(content: "Two", status: .pending)])
        #expect(TodoParser.latest(in: [tool("TodoWrite", first)])?.first?.activeForm == "Doing one")
        // A todo list written after an update_plan list wins, and the other way round.
        #expect(TodoParser.latest(in: [tool(Self.updatePlan, Self.sevenSteps), tool("TodoWrite", second)])?.count == 2)
        #expect(TodoParser.latest(in: [tool("TodoWrite", second), tool(Self.updatePlan, Self.sevenSteps)])?.count == 7)
    }

    @Test func codexStylePlanIsRead() {
        let input = #"{"explanation": "Start", "plan": [{"step": "Read the code", "status": "completed"}, {"step": "Fix it", "status": "in_progress"}]}"#
        let list = TodoParser.latest(in: [tool("update_plan", input)])
        #expect(list == [TodoItem(content: "Read the code", status: .completed), TodoItem(content: "Fix it", status: .inProgress)])
    }

    @Test func taskCreateAndTaskUpdateBuildTheListOneTaskAtATime() {
        var items = [
            tool("TaskCreate", #"{"subject": "Read the code", "description": "x", "activeForm": "Reading the code"}"#,
                 output: "Task #1 created successfully: Read the code"),
            tool("TaskCreate", #"{"subject": "Fix the bug"}"#, output: "Task #2 created successfully: Fix the bug"),
            tool("TaskCreate", #"{"subject": "Run the tests"}"#, output: "Task #3 created successfully: Run the tests"),
            tool("TaskUpdate", #"{"taskId": "1", "status": "in_progress"}"#),
        ]
        var list = TodoParser.latest(in: items)
        #expect(list?.map(\.content) == ["Read the code", "Fix the bug", "Run the tests"])
        #expect(list?.map(\.status) == [.inProgress, .pending, .pending])
        #expect(list?.first?.activeForm == "Reading the code")

        items += [
            tool("TaskUpdate", #"{"taskId": "1", "status": "completed"}"#),
            tool("TaskUpdate", #"{"taskId": 2, "status": "deleted"}"#),
            tool("TaskUpdate", #"{"taskId": "3", "status": "in_progress", "subject": "Run every test"}"#),
            tool("TaskUpdate", #"{"taskId": "77", "status": "completed"}"#),
            tool("TaskList", "{}"),
        ]
        list = TodoParser.latest(in: items)
        #expect(list == [TodoItem(content: "Read the code", status: .completed, activeForm: "Reading the code"),
                         TodoItem(content: "Run every test", status: .inProgress)])
        // Without a readable result the tasks are numbered in order.
        let unnumbered = [tool("TaskCreate", #"{"subject": "A"}"#), tool("TaskCreate", #"{"subject": "B"}"#),
                          tool("TaskUpdate", #"{"taskId": "2", "status": "completed"}"#)]
        #expect(statuses(unnumbered) == [.pending, .completed])
    }

    @Test func planToolsReadAsPlanUpdatesWhateverTheirName() {
        for name in [Self.updatePlan, "update_plan", "TodoWrite", "todowrite", "TaskCreate", "TaskUpdate", Self.wrapUp] {
            #expect(TodoParser.isPlanTool(name), "\(name)")
            #expect(ToolCategory(name) == .plan, "\(name)")
            let summary = ToolSummary(ToolCallInfo(id: "t", name: name, title: name, status: .succeeded))
            #expect(summary.verb == "Updated the plan" && summary.subject.isEmpty, "\(name)")
        }
        for name in ["bash", "mcp__notes__wrap_up", "mcp__x__plan_trip", "Task", "TaskStop"] {
            #expect(!TodoParser.isPlanTool(name), "\(name)")
        }
        #expect(ToolCategory("Task") == .subagent)
        // Only the whole-list todo tools count for the ACP rename (`ACPTranscript`).
        #expect(TodoParser.isTodoTool("todowrite") && !TodoParser.isTodoTool(Self.updatePlan))
        let group: [TranscriptItem] = [tool(Self.updatePlan, Self.sevenSteps), tool(Self.updatePlan, #"{"advance": true}"#)]
        #expect(TranscriptGrouping.summary(group) == "Updated the plan")
    }

    /// A stored Claude transcript whose plan comes from `update_plan`, as in sessions imported from the desktop app.
    @Test func aStoredClaudeTranscriptGivesTheSameList() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func assistant(_ uuid: String, parent: String?, toolID: String, name: String, input: [String: Any]) throws -> String {
            try line(["type": "assistant", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": "2026-11-17T01:00:00.000Z",
                      "message": ["id": "msg_\(uuid)", "role": "assistant",
                                  "content": [["type": "tool_use", "id": toolID, "name": name, "input": input]]]])
        }
        func result(_ uuid: String, parent: String, toolID: String, text: String, isError: Bool = false) throws -> String {
            try line(["type": "user", "uuid": uuid, "parentUuid": parent, "timestamp": "2026-11-17T01:00:01.000Z",
                      "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": text,
                                                               "is_error": isError]]]])
        }
        let lines = [
            try line(["type": "user", "uuid": "u1", "parentUuid": NSNull(), "timestamp": "2026-11-17T00:59:00.000Z",
                      "message": ["role": "user", "content": "Merge the branches"]]),
            try assistant("a1", parent: "u1", toolID: "toolu_1", name: Self.updatePlan,
                          input: ["items": [["content": "Check repo state", "status": "in_progress"],
                                            ["content": "Merge the five branches and build", "status": "pending"],
                                            ["content": "Run the tests", "status": "pending"]], "scope": "first_task"]),
            try result("r1", parent: "a1", toolID: "toolu_1", text: "Plan shown (3 steps)."),
            try assistant("a2", parent: "r1", toolID: "toolu_2", name: Self.updatePlan, input: ["advance": true]),
            try result("r2", parent: "a2", toolID: "toolu_2", text: "Plan updated: step 2 of 3 is in progress."),
            try assistant("a3", parent: "r2", toolID: "toolu_3", name: Self.updatePlan, input: ["done": [7]]),
            try result("r3", parent: "a3", toolID: "toolu_3", text: "No step 7.", isError: true),
        ]
        let data = ClaudeTranscriptFiles.parse(Data(lines.joined(separator: "\n").utf8))
        let builder = ClaudeTranscriptBuilder(rootID: "root", directory: "/tmp/p", finished: true)
        let list = TodoParser.latest(in: builder.items(from: data.activeChain()))
        #expect(list?.map(\.content) == ["Check repo state", "Merge the five branches and build", "Run the tests"])
        #expect(list?.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func runningTasksLine() {
        #expect(TaskListCard.runningLabel(0) == nil)
        #expect(TaskListCard.runningLabel(-1) == nil)
        #expect(TaskListCard.runningLabel(1) == "1 running task")
        #expect(TaskListCard.runningLabel(2) == "2 running tasks")
    }
}

@MainActor
@Suite("Task list running work count")
struct TaskListRunningWorkTests {
    /// The line under the step in progress counts what the store lists as running for the session and its subagents.
    @Test func theCountComesFromTheStoresBackgroundWork() async throws {
        let store = SessionStore(engine: PreviewEngine(seed: StoreSeed(), delayScale: 0))
        let parent = EngineSession(id: "parent", title: "Parent", directory: "/tmp/p")
        let child = EngineSession(id: "child", parentID: "parent", title: "Export MIDI", directory: "/tmp/p")
        let other = EngineSession(id: "other", title: "Other", directory: "/tmp/p")
        store.seed(StoreSeed(sessions: [parent, child, other], activities: ["child": .working]))
        #expect(store.backgroundWork(forSession: "parent").count == 1)
        #expect(store.backgroundWork(forSession: "other").isEmpty)

        store.seedBackgroundTasks([BackgroundTask(id: "sh1", sessionID: "parent", kind: .shell, title: "swift test"),
                                   BackgroundTask(id: "sh2", sessionID: "other", kind: .shell, title: "npm run dev")])
        #expect(store.backgroundWork(forSession: "parent").count == 2)
        #expect(TaskListCard.runningLabel(store.backgroundWork(forSession: "parent").count) == "2 running tasks")
        #expect(TaskListCard.runningLabel(store.backgroundWork(forSession: "other").count) == "1 running task")
    }
}
