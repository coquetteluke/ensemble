import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

// Plan mode and question cards: model types, each engine's mapping, the store's answers and the iPhone messages.

@Suite struct PlanQuestionModelTests {
    @Test func olderRequestsAndModesStillDecode() throws {
        let old = #"{"id":"p1","sessionID":"s1","kind":"bash","title":"ls","created":800000000}"#
        let request = try JSONDecoder().decode(PermissionRequest.self, from: Data(old.utf8))
        #expect(request.plan == nil && request.questions == nil && !request.isInteraction)
        for raw in ["ask", "acceptEdits", "auto", "bypass", "plan"] {
            let mode = try JSONDecoder().decode(PermissionMode.self, from: Data("\"\(raw)\"".utf8))
            #expect(mode.rawValue == raw)
        }
    }

    @Test func plansAndQuestionsRoundTrip() throws {
        let plan = PermissionRequest(id: "p", sessionID: "s", kind: InteractionKind.plan, title: "T",
                                     plan: PlanProposal(markdown: "# Do it\n- one", filePath: "/x.md", proceedMode: .auto))
        let question = PermissionRequest(id: "q", sessionID: "s", kind: InteractionKind.question, title: "Which?",
                                         questions: [AgentQuestion(id: "Which?", text: "Which?", options: [.init(label: "A")])])
        for request in [plan, question] {
            let back = try JSONDecoder().decode(PermissionRequest.self, from: JSONEncoder().encode(request))
            #expect(back == request)
        }
        #expect(plan.isPlan && !plan.isQuestion && question.isQuestion && question.isInteraction)
        #expect(plan.plan?.title == "Do it")
    }

    @Test func planModeSitsBetweenAcceptEditsAndAuto() {
        #expect(PermissionMode.allCases == [.ask, .acceptEdits, .plan, .auto, .bypass])
        #expect(PermissionMode.acceptEdits.next == .plan)
        #expect(PermissionMode.plan.next == .auto)
    }

    @Test func linesKeepCodeAndTablesWhole() {
        let markdown = "# Title\n\nIntro line\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n- item"
        let lines = PlanLines.split(markdown)
        #expect(lines == ["# Title", "Intro line", "```swift\nlet a = 1\n\nlet b = 2\n```", "| a | b |\n|---|---|\n| 1 | 2 |", "- item"])
    }

    @Test func feedbackQuotesEachCommentedLineAndNamesNoFiles() {
        let comments = [PlanComment(lineIndex: 3, line: "- Run the tests", text: "Use the filter"),
                        PlanComment(lineIndex: 1, line: "1. Add the ring", text: "  Put it in the status line  "),
                        PlanComment(lineIndex: 2, line: "ignored", text: "   ")]
        let text = PlanLines.feedback(comments)
        #expect(text.hasPrefix("Comments on the plan:"))
        #expect(text.contains("> 1. Add the ring\nPut it in the status line"))
        #expect(text.range(of: "Add the ring")!.lowerBound < text.range(of: "Run the tests")!.lowerBound)
        #expect(!text.contains("ignored"))
        #expect(PlanLines.feedback([]) == PlanLines.keepPlanningMessage)
    }

    @Test func proceedModesAreTheModeBeforePlanAndAuto() {
        #expect(PlanProposal(markdown: "", proceedMode: .acceptEdits).allowedProceedModes == [.acceptEdits, .auto])
        #expect(PlanProposal(markdown: "", proceedMode: .auto).allowedProceedModes == [.auto])
        #expect(PlanProposal(markdown: "").allowedProceedModes == [.acceptEdits, .auto])
    }

    @Test func answersAreCheckedAgainstTheQuestion() {
        let single = AgentQuestion(id: "q", text: "Q", options: [.init(label: "A"), .init(label: "B")], allowsOther: true)
        #expect(single.validated(AgentQuestionAnswer(questionID: "q", selected: ["A", "B"]))?.selected == ["A"])
        #expect(single.validated(AgentQuestionAnswer(questionID: "q", selected: ["Z"])) == nil)
        let typed = single.validated(AgentQuestionAnswer(questionID: "q", selected: ["A"], other: " mine "))
        #expect(typed?.selected == [] && typed?.other == "mine")
        #expect(single.validated(AgentQuestionAnswer(questionID: "other", selected: ["A"])) == nil)
        let multi = AgentQuestion(id: "m", text: "M", options: [.init(label: "A"), .init(label: "B")], multiSelect: true, allowsOther: false)
        let both = multi.validated(AgentQuestionAnswer(questionID: "m", selected: ["B", "A"], other: "x"))
        #expect(both?.selected == ["A", "B"] && both?.other == nil && both?.text == "A, B")
    }

    @Test func planDecisionsRoundTrip() throws {
        for decision in [PlanDecision.proceed(.acceptEdits), .keepPlanning(comments: [PlanComment(lineIndex: 0, line: "x", text: "y")])] {
            #expect(try JSONDecoder().decode(PlanDecision.self, from: JSONEncoder().encode(decision)) == decision)
        }
    }

    @Test func alertsDescribePlans() {
        let plan = PermissionRequest(id: "p", sessionID: "s", kind: InteractionKind.plan, title: "Add a ring", plan: PlanProposal(markdown: "# Add a ring"))
        #expect(SessionAttentionText.ask(plan) == "Plan ready for review: Add a ring")
    }
}

@Suite struct PlanRulesetTests {
    let rules = PermissionRules.ruleset(for: .plan)

    @Test func planModeIsReadOnlyOnOpenCode() {
        #expect(PermissionRules.effect(action: "read", resource: "src/a.swift", rules: rules) == "allow")
        #expect(PermissionRules.effect(action: "grep", resource: "*", rules: rules) == "allow")
        #expect(PermissionRules.effect(action: "edit", resource: "src/a.swift", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "edit", resource: "/Users/me/.opencode/plan/x.md", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "shell", resource: "echo hi > shell.txt", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "shell", resource: "rm -rf build", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "shell", resource: "ls -la", rules: rules) == "allow")
        #expect(PermissionRules.effect(action: "shell", resource: "find . -delete", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "execute", resource: "*", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "github_create_issue", resource: "*", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "external_directory", resource: "/etc", rules: rules) == "deny")
        #expect(PermissionRules.effect(action: "webfetch", resource: "https://example.com", rules: rules) == "ask")
        #expect(PermissionRules.effect(action: "question", resource: "*", rules: rules) == "allow")
    }

    @Test func planRulesAreRecognisedAndNeverOutdated() {
        #expect(PermissionRules.mode(for: rules) == .plan)
        #expect(PermissionRules.outdatedMode(for: rules) == nil)
        #expect(PermissionRules.agent(for: .plan) == "plan")
        #expect(PermissionRules.agent(for: .auto) == "build")
    }

    @Test func roomWorktreesGetNoAllowInPlan() {
        #expect(PermissionRules.ruleset(for: .plan, worktree: ".ensemble/worktrees/ada") == rules)
    }
}

@Suite struct ClaudeInteractionTests {
    func prompt(_ tool: String, _ input: JSONValue) -> ClaudePermissionPrompt {
        ClaudePermissionPrompt(requestID: "req-1", sessionID: "root", body: ["tool_name": .string(tool), "input": input,
                                                                               "requires_user_interaction": true],
                               directory: "/tmp/p")
    }

    let questionInput: JSONValue = ["questions": [[
        "question": "Which color do you prefer?", "header": "Color", "multiSelect": false,
        "options": [["label": "Red", "description": "warm"], ["label": "Blue", "description": "cool"]],
    ]]]

    @Test func askUserQuestionBecomesAQuestionCard() throws {
        let p = prompt("AskUserQuestion", questionInput)
        #expect(p.isQuestion && p.request.isQuestion && p.request.kind == InteractionKind.question)
        let question = try #require(p.request.questions?.first)
        #expect(question.id == "Which color do you prefer?" && question.header == "Color" && question.allowsOther)
        #expect(question.options.map(\.label) == ["Red", "Blue"] && question.options[0].detail == "warm")
        #expect(p.request.alwaysPatterns == nil)
    }

    /// The shape checked live against claude 2.1.319: allow with `updatedInput` = input plus `answers`.
    @Test func answersGoBackAsUpdatedInput() throws {
        let p = prompt("AskUserQuestion", questionInput)
        let reply = p.questionResponse(answers: [AgentQuestionAnswer(questionID: "Which color do you prefer?", selected: ["Blue"])])
        let behavior = try #require(reply["response"]?["response"])
        #expect(reply["response"]?["request_id"]?.stringValue == "req-1")
        #expect(behavior["behavior"]?.stringValue == "allow")
        #expect(behavior["updatedInput"]?["answers"]?["Which color do you prefer?"]?.stringValue == "Blue")
        #expect(behavior["updatedInput"]?["questions"] == questionInput["questions"])
        let typed = p.questionResponse(answers: [AgentQuestionAnswer(questionID: "Which color do you prefer?", other: "Green")])
        #expect(typed["response"]?["response"]?["updatedInput"]?["answers"]?["Which color do you prefer?"]?.stringValue == "Green")
        let declined = p.questionResponse(answers: [])
        #expect(declined["response"]?["response"]?["behavior"]?.stringValue == "deny")
    }

    @Test func exitPlanModeBecomesAPlanCard() throws {
        let p = prompt("ExitPlanMode", ["plan": "# Plan\n1. Do it", "planFilePath": "/Users/me/.claude/plans/x.md"])
        #expect(p.isPlan && p.request.isPlan)
        #expect(p.request.plan?.markdown == "# Plan\n1. Do it" && p.request.plan?.filePath == "/Users/me/.claude/plans/x.md")
        let proceed = p.planResponse(.proceed(.acceptEdits))["response"]?["response"]
        #expect(proceed?["behavior"]?.stringValue == "allow" && proceed?["updatedInput"]?["plan"]?.stringValue == "# Plan\n1. Do it")
        let keep = p.planResponse(.keepPlanning(comments: [PlanComment(lineIndex: 1, line: "1. Do it", text: "Do it later")]))["response"]?["response"]
        #expect(keep?["behavior"]?.stringValue == "deny")
        #expect(keep?["message"]?.stringValue?.contains("> 1. Do it\nDo it later") == true)
    }

    @Test func planGuardAddsBashToAskAndRestoresTheSettingsFile() {
        let on = ClaudePlanGuard.settings(planOn: true, base: nil)
        #expect(on == ["permissions": ["ask": ["Bash"]]])
        #expect(ClaudePlanGuard.settings(planOn: false, base: nil) == ["permissions": ["ask": []]])
        let base: JSONValue = ["deny": ["WebFetch"], "ask": ["Bash(git push:*)"]]
        #expect(ClaudePlanGuard.settings(planOn: true, base: base) == ["permissions": ["deny": ["WebFetch"], "ask": ["Bash(git push:*)", "Bash"]]])
        #expect(ClaudePlanGuard.settings(planOn: false, base: base) == ["permissions": base])
        #expect(ClaudePermissionModes.cliMode(.plan) == "plan" && ClaudePermissionModes.ensembleMode("plan") == .plan)
    }

    @Test func editsAreRefusedNotAskedInPlan() {
        let p = prompt("Write", ["file_path": "/tmp/p/a.txt", "content": "x"])
        let reply = p.planEditRefusal()["response"]?["response"]
        #expect(reply?["behavior"]?.stringValue == "deny")
        #expect(reply?["message"]?.stringValue?.contains("read-only") == true)
    }
}

@Suite struct OpenCodeInteractionTests {
    let formCreated = """
    {"id":"evt_1","created":1794985900484,"type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1","title":"Questions",\
    "metadata":{"kind":"question","tool":{"messageID":"msg_1","id":"call_1"}},"fields":[{"key":"q0","title":"Color",\
    "description":"Which color?","type":"string","options":[{"value":"Red","label":"Red","description":"warm"},\
    {"value":"Blue","label":"Blue","description":"cool"}],"custom":true},{"key":"q1","title":"Fruits","type":"multiselect",\
    "options":[{"value":"a","label":"Apple"},{"value":"p","label":"Pear"}]},{"key":"q2","title":"Sure?","type":"boolean"}]}}}
    """

    /// The event captured live from OpenCode 2.3 with the mock model, plus two more field types.
    @Test func formsBecomeQuestions() throws {
        var decoder = EngineEventDecoder()
        let outputs = decoder.decode(formCreated)
        guard case .event(.permissionAsked(let request))? = outputs.first else {
            Issue.record("no permissionAsked: \(outputs)")
            return
        }
        #expect(request.id == "frm_1" && request.sessionID == "ses_1" && request.isQuestion)
        let questions = try #require(request.questions)
        #expect(questions.map(\.id) == ["q0", "q1", "q2"])
        #expect(questions[0].text == "Which color?" && questions[0].header == "Color" && questions[0].allowsOther)
        #expect(questions[1].multiSelect && !questions[1].allowsOther && questions[1].options.map(\.label) == ["Apple", "Pear"])
        #expect(questions[2].options.map(\.label) == ["Yes", "No"])
        let replied = decoder.decode(#"{"type":"form.replied","data":{"id":"frm_1","sessionID":"ses_1","answer":{"q0":"Blue"}}}"#)
        #expect(replied.first == .event(.permissionReplied(sessionID: "ses_1", requestID: "frm_1")))
        let cancelled = decoder.decode(#"{"type":"form.cancelled","data":{"id":"frm_1","sessionID":"ses_1"}}"#)
        #expect(cancelled == [.event(.permissionReplied(sessionID: "ses_1", requestID: "frm_1"))])
    }

    @Test func answersTakeEachFieldsType() throws {
        var decoder = EngineEventDecoder()
        guard case .event(.permissionAsked(let request))? = decoder.decode(formCreated).first,
              let questions = request.questions else { Issue.record("no request"); return }
        let data = try #require(formCreated.data(using: .utf8))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let fields = try #require(json["data"]?["form"]?["fields"]?.arrayValue)
        let answer = OpenCodeForms.answer(fields: fields, questions: questions, answers: [
            AgentQuestionAnswer(questionID: "q0", selected: ["Blue"]),
            AgentQuestionAnswer(questionID: "q1", selected: ["Pear", "Apple"]),
            AgentQuestionAnswer(questionID: "q2", selected: ["No"]),
        ])
        #expect(answer == ["q0": "Blue", "q1": ["a", "p"], "q2": false])
        let typed = OpenCodeForms.answer(fields: fields, questions: questions, answers: [AgentQuestionAnswer(questionID: "q0", other: "Green")])
        #expect(typed == ["q0": "Green"])
    }
}

@Suite struct ACPInteractionTests {
    /// The request agy 1.5.10 sent (captured 2026-11-18) for one single-choice and one multi-choice question.
    let params: JSONValue = [
        "sessionId": "agent-1", "toolCallId": "call_1", "mode": "form", "message": "The agent has 2 questions.",
        "requestedSchema": ["type": "object", "properties": [
            "q1": ["type": "string", "title": "Which color do you prefer?",
                   "oneOf": [["const": "1", "title": "(Recommended) Red"], ["const": "2", "title": "Blue"]]],
            "q1_other": ["type": "string", "title": "Other", "description": "Optional free-form answer"],
            "q2": ["type": "array", "title": "Which fruits do you like?",
                   "items": ["anyOf": [["const": "1", "title": "Apple"], ["const": "2", "title": "Pear"], ["const": "3", "title": "Plum"]]]],
            "q2_other": ["type": "string", "title": "Other"],
        ]],
    ]

    @Test func agyElicitationBecomesQuestions() throws {
        let form = try #require(ACPElicitation(params: params))
        #expect(form.questions.map(\.id) == ["q1", "q2"])
        #expect(form.questions[0].text == "Which color do you prefer?" && !form.questions[0].multiSelect && form.questions[0].allowsOther)
        #expect(form.questions[0].options.map(\.label) == ["(Recommended) Red", "Blue"])
        #expect(form.questions[1].multiSelect && form.questions[1].options.count == 3)
        let result = form.result(for: [AgentQuestionAnswer(questionID: "q1", selected: ["Blue"]),
                                       AgentQuestionAnswer(questionID: "q2", selected: ["Apple", "Plum"], other: "Kiwi")])
        #expect(result == ["action": "accept", "content": ["q1": "2", "q2": ["1", "3"], "q2_other": "Kiwi"]])
        let typed = form.result(for: [AgentQuestionAnswer(questionID: "q1", other: "Green")])
        #expect(typed == ["action": "accept", "content": ["q1_other": "Green"]])
        #expect(form.result(for: []) == ACPElicitation.declined)
        #expect(ACPElicitation(params: ["mode": "url", "requestedSchema": params["requestedSchema"]!]) == nil)
    }

    /// agy's plan artifact (the `write_file` call seen in plan mode, 2026-11-18).
    @Test func planArtifactIsFound() throws {
        let input: JSONValue = ["ArtifactMetadata": ["RequestFeedback": true, "Summary": "Plan", "UserFacing": true],
                                "Content": "# Implementation Plan\n- step", "Overwrite": true, "Path": "/Users/me/.gemini/brain/x/plan.md"]
        let plan = try #require(ACPPlanArtifact.plan(in: input))
        #expect(plan.markdown == "# Implementation Plan\n- step" && plan.filePath == "/Users/me/.gemini/brain/x/plan.md")
        #expect(ACPPlanArtifact.plan(in: ["Content": "x", "Path": "/a"]) == nil)
        let items: [TranscriptItem] = [.user(id: "u", text: "go", date: Date()), .agentText(id: "a", text: " The plan ", agentID: nil, streaming: false)]
        #expect(ACPPlanArtifact.lastReply(in: items) == "The plan")
        #expect(ACPPlanArtifact.lastReply(in: [.agentText(id: "a", text: "old", agentID: nil, streaming: false), .user(id: "u", text: "go", date: Date())]) == nil)
    }

    @Test func agyHasAPlanMode() {
        #expect(ACPModes.modeID(for: .plan, definition: ACPAgentRegistry.antigravity, available: ["default", "plan"]) == "plan")
        // A mode merely called "plan" is not trusted to be read-only.
        #expect(ACPModes.modeID(for: .plan, definition: ACPAgentRegistry.openCode, available: ["build", "plan"]) == nil)
    }
}

/// An engine with plans and questions that records what it was asked, and whose plans end the turn (a message follows).
final class InteractionTestEngine: PreviewForwarding, EngineInteractionControl, Sendable {
    let base = PreviewEngine(seed: PreviewData.seed(), delayScale: 0)
    let support: PlanModeSupport
    let followUp: String?
    private let log = Mutex<[String]>([])

    init(support: PlanModeSupport = .supported, followUp: String? = "Go") {
        self.support = support
        self.followUp = followUp
    }

    var calls: [String] { log.withLock { $0 } }

    func planModeSupport(sessionID: String) async -> PlanModeSupport { support }

    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        log.withLock { $0.append("answer:\(sessionID):\(requestID):\(answers.map(\.text).joined(separator: "|"))") }
    }

    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        switch decision {
        case .proceed(let mode): log.withLock { $0.append("proceed:\(sessionID):\(requestID):\(mode.rawValue)") }
        case .keepPlanning(let comments): log.withLock { $0.append("keep:\(sessionID):\(requestID):\(comments.count)") }
        }
        return followUp
    }

    func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        log.withLock { $0.append("prompt:\(sessionID):\(text)") }
    }
}

@MainActor
@Suite("Plans and questions in the store", .serialized)
struct PlanQuestionStoreTests {
    let main = PreviewData.mainSessionID

    func store(_ engine: any OpenCodeAPI) -> SessionStore {
        let store = SessionStore(engine: engine)
        var seed = PreviewData.seed()
        seed.permissions = []
        store.seed(seed)
        return store
    }

    func question(_ id: String = "q1", session: String) -> PermissionRequest {
        PermissionRequest(id: id, sessionID: session, kind: InteractionKind.question, title: "Which?",
                          questions: [AgentQuestion(id: "Which?", text: "Which?", options: [.init(label: "A"), .init(label: "B")])])
    }

    func plan(_ id: String = "p1", session: String) -> PermissionRequest {
        PermissionRequest(id: id, sessionID: session, kind: InteractionKind.plan, title: "Plan", plan: PlanProposal(markdown: "# Plan"))
    }

    @Test func questionsJoinThePendingListAndAnswersReachTheirSession() async throws {
        let engine = InteractionTestEngine()
        let store = store(engine)
        store.apply(.permissionAsked(question(session: main)))
        let request = try #require(store.openQuestion(in: main))
        #expect(store.needsYouCount(main) == 1)
        #expect(store.attentionSnapshots().first { $0.id == main }?.needsYou == true)
        #expect(await store.answerQuestion(request, answers: [AgentQuestionAnswer(questionID: "Which?", selected: ["B"])]))
        #expect(engine.calls == ["answer:\(main):q1:B"])
        #expect(store.openQuestion(in: main) == nil && store.session(main)?.resolutions["q1"] != nil)
        #expect(store.interactionOutcomes["q1"] == .answered([AgentQuestionAnswer(questionID: "Which?", selected: ["B"])]))
    }

    @Test func unansweredQuestionsAndAllowAreRefused() async throws {
        let engine = InteractionTestEngine()
        let store = store(engine)
        store.apply(.permissionAsked(question(session: main)))
        let request = try #require(store.openQuestion(in: main))
        #expect(await store.answerQuestion(request, answers: [AgentQuestionAnswer(questionID: "Which?", selected: ["Z"])]) == false)
        await store.reply(to: request, decision: .once)
        #expect(engine.calls.isEmpty && store.openQuestion(in: main) != nil)
        await store.reply(to: request, decision: .reject)
        #expect(engine.calls == ["answer:\(main):q1:"] && store.interactionOutcomes["q1"] == .declined)
    }

    @Test func proceedSwitchesToTheModeBeforePlanAndSendsTheFollowUp() async throws {
        let engine = InteractionTestEngine()
        let store = store(engine)
        await store.setPermissionMode(.acceptEdits, for: main)
        await store.setPermissionMode(.plan, for: main)
        #expect(store.session(main)?.permissionMode == .plan)
        store.apply(.permissionAsked(plan(session: main)))
        let request = try #require(store.session(main)?.pendingPermissions.first)
        #expect(request.plan?.proceedMode == .acceptEdits)
        // Only the modes the card offers.
        #expect(await store.respondToPlan(request, decision: .proceed(.bypass)) == false)
        #expect(await store.respondToPlan(request, decision: .proceed(.acceptEdits)))
        #expect(store.session(main)?.permissionMode == .acceptEdits)
        #expect(engine.calls == ["proceed:\(main):p1:acceptEdits", "prompt:\(main):Go"])
        #expect(store.interactionOutcomes["p1"] == .proceeded(.acceptEdits))
        #expect(store.session(main)?.items.contains { if case .user(_, "Go", _) = $0 { true } else { false } } == true)
    }

    @Test func keepPlanningSendsTheCommentsAndStaysInPlan() async throws {
        let engine = InteractionTestEngine(followUp: nil)
        let store = store(engine)
        await store.setPermissionMode(.plan, for: main)
        store.apply(.permissionAsked(plan(session: main)))
        let request = try #require(store.session(main)?.pendingPermissions.first)
        let comments = [PlanComment(lineIndex: 0, line: "# Plan", text: "Shorter")]
        #expect(await store.respondToPlan(request, decision: .keepPlanning(comments: comments)))
        #expect(engine.calls == ["keep:\(main):p1:1"])
        #expect(store.session(main)?.permissionMode == .plan)
        #expect(store.interactionOutcomes["p1"] == .keptPlanning(commentCount: 1))
    }

    @Test func planModeIsRefusedWhereTheEngineHasNone() async {
        let engine = InteractionTestEngine(support: .unsupported(reason: "No plan mode here."))
        let store = store(engine)
        await store.setPermissionMode(.acceptEdits, for: main)
        await store.setPermissionMode(.plan, for: main)
        #expect(store.session(main)?.permissionMode == .acceptEdits)
        #expect(store.lastError == "No plan mode here.")
        #expect(store.nextPermissionMode(for: main) == .auto)
        let plain = self.store(PlainTestEngine())
        await plain.setPermissionMode(.plan, for: main)
        #expect(plain.session(main)?.permissionMode != .plan)
    }
}

@Suite struct PlanQuestionRemoteTests {
    @Test func newMessagesRoundTripAndOlderOnesAreUnchanged() throws {
        let messages: [RemoteClientMessage] = [
            .answerQuestion(RemoteQuestionAnswer(sessionID: "s1", requestID: "q1",
                                                 answers: [AgentQuestionAnswer(questionID: "Which?", selected: ["A"], other: "x")])),
            .respondToPlan(RemotePlanResponse(sessionID: "s1", requestID: "p1", decision: .proceed(.auto))),
            .respondToPlan(RemotePlanResponse(sessionID: "s1", requestID: "p1", decision: .keepPlanning(comments: []))),
        ]
        for message in messages {
            let frame = RemoteClientFrame(message, id: "1")
            #expect(try RemoteCoding.decode(RemoteClientFrame.self, from: RemoteCoding.encode(frame)) == frame)
        }
        let old = #"{"v":3,"id":"2","type":"replyPermission","data":{"sessionID":"s1","requestID":"p1","decision":"once"}}"#
        let frame = try RemoteCoding.decode(RemoteClientFrame.self, from: Data(old.utf8))
        #expect(frame.message == .replyPermission(RemotePermissionReply(sessionID: "s1", requestID: "p1", decision: .once)))
    }

    @Test func demoHostAnswersOnlyTheSessionThatAsked() async throws {
        var data = RemoteDemoData.sample()
        let sessionID = try #require(data.sessions.first?.id)
        let question = PermissionRequest(id: "q9", sessionID: sessionID, kind: InteractionKind.question, title: "Which?",
                                         questions: [AgentQuestion(id: "Which?", text: "Which?", options: [.init(label: "A")])])
        let plan = PermissionRequest(id: "p9", sessionID: sessionID, kind: InteractionKind.plan, title: "Plan",
                                     plan: PlanProposal(markdown: "# Plan", proceedMode: .acceptEdits))
        data.permissions += [question, plan]
        let host = DemoRemoteHost(data: data)
        let wrong = await RemoteDispatcher.respond(to: .answerQuestion(RemoteQuestionAnswer(sessionID: "other", requestID: "q9", answers: [])), host: host)
        if case .error(let error) = wrong { #expect(error.code == .notFound) } else { Issue.record("answer reached another session") }
        let bypass = await RemoteDispatcher.respond(to: .respondToPlan(RemotePlanResponse(sessionID: sessionID, requestID: "p9", decision: .proceed(.bypass))), host: host)
        if case .error(let error) = bypass { #expect(error.code == .badRequest) } else { Issue.record("bypass was accepted") }
        let answered = await RemoteDispatcher.respond(to: .answerQuestion(RemoteQuestionAnswer(
            sessionID: sessionID, requestID: "q9", answers: [AgentQuestionAnswer(questionID: "Which?", selected: ["A"])])), host: host)
        #expect(answered == .ack)
        #expect(await RemoteDispatcher.respond(to: .respondToPlan(RemotePlanResponse(sessionID: sessionID, requestID: "p9",
                                                                                     decision: .proceed(.acceptEdits))), host: host) == .ack)
        #expect(await host.permissions.contains { $0.id == "q9" || $0.id == "p9" } == false)
    }
}
