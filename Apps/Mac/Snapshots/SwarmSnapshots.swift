import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the room swarm views and goal mode to PNG files (2x), dark and light, at the requested zoom and at 1.5 times
/// it: a team room with an active goal (Members, the message graph), replay part way through the board, Follow on the
/// working agent, the goal bar's states with the Goal editor and the session pill, and a solo room whose goal was met.
/// Call from the `--render-snapshots` flow: `SwarmSnapshots.render(to: outputDirectory, zoom: zoom)`.
@MainActor
enum SwarmSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seed = SwarmSeed()
        var written: [String] = []

        func save<V: View>(_ name: String, width: CGFloat, height: CGFloat?, scheme: ColorScheme, zoom: CGFloat, grows: Bool,
                           @ViewBuilder _ view: () -> V) {
            let w = grows ? width * zoom : width
            let h = grows ? height.map { $0 * zoom } : height
            let content = SwarmCanvas(width: w, height: h) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: w, height: h)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = directory.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        for scale in [zoom, zoom * 1.5] {
            let suffix = scale == 1 ? "" : "-\(Int((scale * 100).rounded()))"
            for scheme in [ColorScheme.dark, .light] {
                let tone = scheme == .dark ? "dark" : "light"
                // Whole rooms keep their size and zoom their content, like windows.
                save("swarm-room-goal-\(tone)\(suffix)", width: 1240, height: 900, scheme: scheme, zoom: scale, grows: false) {
                    RoomView(controller: seed.controller, engine: seed.team)
                }
                save("swarm-replay-\(tone)\(suffix)", width: 1240, height: 900, scheme: scheme, zoom: scale, grows: false) {
                    RoomView(controller: seed.controller, engine: seed.team, initialReplayStep: seed.replayStep)
                }
                save("swarm-follow-\(tone)\(suffix)", width: 1240, height: 900, scheme: scheme, zoom: scale, grows: false) {
                    RoomView(controller: seed.controller, engine: seed.team, initialAgentID: seed.gpt.id, initialFollow: true)
                }
                // The panel alone, to read Members and the graph closely.
                save("swarm-members-graph-\(tone)\(suffix)", width: 303, height: 880, scheme: scheme, zoom: scale, grows: true) {
                    RoomSidePanel(controller: seed.controller, engine: seed.team, selectedAgentID: .constant(nil), topInset: 12)
                }
                save("swarm-goal-states-\(tone)\(suffix)", width: 760, height: nil, scheme: scheme, zoom: scale, grows: true) {
                    GoalStatesSheet(seed: seed)
                }
                save("swarm-room-goal-met-\(tone)\(suffix)", width: 1100, height: 640, scheme: scheme, zoom: scale, grows: false) {
                    RoomView(controller: seed.controller, engine: seed.solo)
                }
            }
        }
        print("Rendered \(written.count) swarm snapshots:")
        for path in written { print(path) }
        return written
    }
}

private struct SwarmCanvas<Content: View>: View {
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

/// The goal bar in each state, the Goal editor and a session's goal pill.
private struct GoalStatesSheet: View {
    let seed: SwarmSeed
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(12)) {
            ForEach(Array(seed.goalStates.enumerated()), id: \.offset) { _, item in
                GoalBarContent(goal: item.goal, waitingOnYou: item.waiting,
                               statusText: item.waiting ? "Waiting on you" : item.goal.statusLine, stop: {}, clear: {})
            }
            HStack(alignment: .top, spacing: theme.z(16)) {
                GoalEditor(initialCondition: "swift test passes with no failures", start: { _, _ in }, cancel: {})
                    .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.popover))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
                VStack(alignment: .leading, spacing: theme.z(10)) {
                    GoalPill(goal: seed.sessionGoal, stop: {}, clear: {})
                    GoalPill(goal: seed.goalStates[2].goal, stop: {}, clear: {})
                }
            }
        }
        .padding(theme.z(20))
    }
}

/// A team room part way through a goal, and a solo room whose goal was met.
@MainActor
struct SwarmSeed {
    let controller: RoomsController
    let team: RoomEngine
    let solo: RoomEngine
    let gpt: AgentSpec
    /// The replay snapshot stops here.
    let replayStep: Int
    let goalStates: [(goal: GoalRun, waiting: Bool)]
    let sessionGoal: GoalRun

    init() {
        let api = PreviewEngine()
        let store = InMemoryRoomStore()
        let models = PreviewData.seed().models
        let folder = NSHomeDirectory() + "/Ensemble"
        let start = Date().addingTimeInterval(-2400)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

        let opus = AgentSpec(name: "Opus", model: ModelRef(providerID: "anthropic", id: "claude-opus-5-5"),
                             role: "Plans and builds the model layer", colorHex: "#A78BFA", spendingCapUSD: 3)
        let gpt = AgentSpec(name: "GPT", model: ModelRef(providerID: "openai", id: "gpt-5.5"), role: "Builds the views", colorHex: "#34D399")
        let haiku = AgentSpec(name: "Haiku", model: ModelRef(providerID: "anthropic", id: "claude-haiku-5"),
                              role: "Writes the tests", colorHex: "#60A5FA", spendingCapUSD: 1)
        let gemini = AgentSpec(name: "Gemini", model: ModelRef(providerID: "google", id: "gemini-3-pro"),
                               role: "Reviews", colorHex: "#FBBF24")
        self.gpt = gpt

        var t = RoomState(spec: RoomSpec(title: "Settings screen", directory: folder, agents: [opus, gpt, haiku, gemini], mode: .team,
                                         leadAgentID: opus.id, permissionMode: .auto, created: at(0)))
        t.run = 2
        t.phase = .working
        t.task = "Goal: all tests pass"
        t.sessions = [opus.id: "ses_sw_opus", gpt.id: "ses_sw_gpt", haiku.id: "ses_sw_haiku", gemini.id: "ses_sw_gemini"]
        t.git = GitContext(isRepository: true, baseBranch: "main")
        t.plan = "Fix the trimming bug first, then the view test.\nASSIGN @Opus: trim keys in SettingsModel\nASSIGN @GPT: SettingsView error state\nASSIGN @Haiku: tests for keys with spaces\nASSIGN @Gemini: review"
        t.assignments = [
            Assignment(agentID: opus.id, task: "Trim keys in SettingsModel", status: .approved, reviewerID: gemini.id,
                       branch: "ensemble/settings-screen/opus", changedFiles: ["Sources/App/SettingsModel.swift"]),
            Assignment(agentID: gpt.id, task: "SettingsView error state", status: .working, reviewerID: haiku.id,
                       branch: "ensemble/settings-screen/gpt"),
            Assignment(agentID: haiku.id, task: "Tests for keys with spaces", status: .working, reviewerID: opus.id,
                       branch: "ensemble/settings-screen/haiku"),
        ]
        t.duties = [gpt.id: [Duty(purpose: .work)], haiku.id: [Duty(purpose: .work)]]
        t.usage = [opus.id: Usage(inputTokens: 210_000, outputTokens: 11_200, costUSD: 1.12),
                   gpt.id: Usage(inputTokens: 120_000, outputTokens: 8_400, costUSD: 0.58),
                   haiku.id: Usage(inputTokens: 72_000, outputTokens: 4_600, costUSD: 0.09),
                   gemini.id: Usage(inputTokens: 40_000, outputTokens: 2_100, costUSD: 0.11)]
        t.board = [
            BoardMessage(from: .user, kind: .chat, text: "Goal: all tests pass", date: at(0)),
            BoardMessage(from: .agent(opus.id), kind: .plan, text: "PLAN: Settings in three pieces, Gemini reviews.", date: at(1)),
            BoardMessage(from: .agent(gpt.id), to: [opus.id], kind: .question, text: "Do keyless models show greyed out?", date: at(3)),
            BoardMessage(from: .agent(opus.id), to: [gpt.id], kind: .chat, text: "Yes, greyed out with \"no key\".", date: at(4)),
            BoardMessage(from: .agent(haiku.id), to: [opus.id], kind: .question, text: "Trimmed, or rejected?", date: at(8)),
            BoardMessage(from: .agent(opus.id), to: [haiku.id], kind: .chat, text: "Trimmed. Only whitespace-only keys are rejected.", date: at(9)),
            BoardMessage(from: .agent(gemini.id), to: [opus.id], kind: .review, text: "APPROVE", date: at(12)),
            BoardMessage(from: .agent(opus.id), kind: .update, text: "Summary: model and view are in; one test still fails.", date: at(14)),
            BoardMessage(from: .room, kind: .notice, text: "Gemini checks the goal.", date: at(15)),
            BoardMessage(from: .agent(gemini.id), kind: .review, text: "Ran `swift test`: 41 pass, 1 fails.\nGOAL NOT MET: SettingsTests fails on a key with spaces.", date: at(16)),
            BoardMessage(from: .room, kind: .notice, text: "Goal not met yet: SettingsTests fails on a key with spaces. Run 2 of 10 starts.", date: at(16.2)),
            BoardMessage(from: .agent(opus.id), kind: .plan, text: "PLAN: Opus trims keys, GPT adds the error state, Haiku covers spaces.", date: at(17)),
            BoardMessage(from: .agent(haiku.id), to: [gpt.id], kind: .question, text: "Which label does the error state use?", date: at(21)),
            BoardMessage(from: .agent(gpt.id), to: [haiku.id], kind: .chat, text: "\"Key has spaces at the ends\". Test for that text.", date: at(22)),
            BoardMessage(from: .agent(haiku.id), to: [gpt.id], kind: .chat, text: "Got it, writing that test now.", date: at(23)),
        ]
        var goal = GoalDriver.start(condition: "all tests pass", budget: GoalBudget(maxTurns: 10, maxCostUSD: 5), costNow: 0, unit: "run").0
        goal.turns = 2
        goal.checks = 1
        goal.costSpent = 1.9
        goal.lastReason = "SettingsTests fails on a key with spaces."
        t.goal = goal
        team = RoomEngine(state: t, api: api, store: store)
        replayStep = 7

        // Solo room: the goal was met after two runs.
        let sonnet = AgentSpec(name: "Sonnet", model: ModelRef(providerID: "anthropic", id: "claude-sonnet-5"), colorHex: "#F472B6")
        var s = RoomState(spec: RoomSpec(title: "Fix the flaky test", directory: folder, agents: [sonnet], mode: .solo,
                                         leadAgentID: sonnet.id, permissionMode: .acceptEdits, created: at(-300)))
        s.run = 2
        s.phase = .finished
        s.sessions = [sonnet.id: "ses_sw_sonnet"]
        s.usage = [sonnet.id: Usage(inputTokens: 44_000, outputTokens: 3_100, costUSD: 0.21)]
        s.board = [
            BoardMessage(from: .user, kind: .chat, text: "Goal: RemoteLoopbackTests pass ten runs in a row", date: at(-300)),
            BoardMessage(from: .agent(sonnet.id), kind: .chat, text: "The test waited a fixed 200 ms for the socket. It now waits for the welcome frame.", date: at(-296)),
            BoardMessage(from: .room, kind: .notice, text: "Sonnet checks the goal.", date: at(-295)),
            BoardMessage(from: .agent(sonnet.id), kind: .review, text: "Ran it ten times: 9 passed, 1 timed out on the reconnect case.\nGOAL NOT MET: the reconnect case still times out once in ten.", date: at(-293)),
            BoardMessage(from: .room, kind: .notice, text: "Goal not met yet: the reconnect case still times out once in ten. Run 2 of 5 starts.", date: at(-293)),
            BoardMessage(from: .agent(sonnet.id), kind: .chat, text: "The reconnect case now waits for the second welcome too.", date: at(-288)),
            BoardMessage(from: .room, kind: .notice, text: "Sonnet checks the goal.", date: at(-287)),
            BoardMessage(from: .agent(sonnet.id), kind: .review, text: "Ran `swift test --filter RemoteLoopbackTests` ten times: 10 of 10 pass.\nGOAL MET: 10 of 10 runs pass", date: at(-285)),
            BoardMessage(from: .room, kind: .notice, text: "Goal met: 10 of 10 runs pass", date: at(-285)),
        ]
        var met = GoalDriver.start(condition: "RemoteLoopbackTests pass ten runs in a row", budget: GoalBudget(maxTurns: 5),
                                   costNow: 0, unit: "run").0
        met.turns = 2
        met.checks = 2
        met.costSpent = 0.21
        met.status = .met
        met.evidence = "10 of 10 runs pass"
        s.goal = met
        solo = RoomEngine(state: s, api: api, store: store)

        controller = RoomsController(api: api, store: store, git: nil)
        let prompt = PermissionRequest(id: "perm_sw_haiku", sessionID: "ses_sw_haiku", kind: "shell",
                                       title: "swift test --filter SettingsTests", detail: "Runs the settings tests in Haiku's worktree.",
                                       created: at(24))
        let transcript = AgentTranscript(sessionID: "ses_sw_gpt", agentID: gpt.id, items: [
            .notice(id: "sw1", text: "[Room] Goal: all tests pass\nNot met yet: SettingsTests fails on a key with spaces."),
            .agentText(id: "sw2", text: "I'll add the error state for keys with spaces at the ends.", agentID: gpt.id, streaming: false),
            .tool(ToolCallInfo(id: "sw3", name: "read", title: "Sources/App/SettingsView.swift", status: .succeeded)),
            .tool(ToolCallInfo(id: "sw4", name: "edit", title: "Sources/App/SettingsView.swift", status: .succeeded,
                               diff: "@@ -12,6 +12,9 @@\n             SecureField(\"API key\", text: $model.key)\n+            if model.keyHasOuterSpaces {\n+                Text(\"Key has spaces at the ends\").foregroundStyle(.red)\n+            }\n             ModelPicker(selection: $model.model)")),
            .agentText(id: "sw5", text: "@Haiku The error label reads \"Key has spaces at the ends\". Test for that text.", agentID: gpt.id, streaming: false),
            .tool(ToolCallInfo(id: "sw6", name: "shell", title: "swift build", status: .running)),
        ], loaded: true)
        controller.seed(engines: [solo, team], models: models, permissions: [prompt], transcripts: [transcript])
        controller.selectedRoomID = team.state.id
        controller.activityOverride = [gpt.id: .working, haiku.id: .waitingForPermission]
        controller.liveTextOverride = [gpt.id: "Building the view with the new error state, then I'll run the view tests."]

        // The goal bar's states.
        var checking = goal
        checking.status = .checking
        var waiting = goal
        waiting.status = .working
        var budget = GoalDriver.start(condition: "the docs site builds without warnings", budget: GoalBudget(maxTurns: 3), costNow: 0, unit: "run").0
        budget.turns = 3
        budget.costSpent = 0.74
        budget.status = .budgetReached
        budget.note = "Budget used up after 3 runs"
        var stopped = GoalDriver.start(condition: "lint is clean", budget: GoalBudget(), costNow: 0, unit: "run").0
        stopped.status = .stopped
        stopped.note = "Stopped by you"
        stopped.costSpent = 0.12
        goalStates = [(goal, false), (checking, false), (met, false), (waiting, true), (budget, false), (stopped, false)]

        var session = GoalDriver.start(condition: "all tests pass", budget: GoalBudget(), costNow: 0).0
        session.turns = 3
        sessionGoal = session
    }
}
