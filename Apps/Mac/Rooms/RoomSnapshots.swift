import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the room screens with seeded rooms to PNG files (2x): the new room sheet, a room in each mode,
/// a plan waiting for approval, an agent's own session, the sidebar section, and the team room at 150% zoom.
/// Call from the `--render-snapshots` flow: `RoomSnapshots.render(to: outputDirectory, zoom: zoom)`.
/// Room views keep their size and zoom their content (like whole windows); the sheet and the sidebar grow.
@MainActor
enum RoomSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(directory.path): \(error.localizedDescription)")
            return []
        }
        let seed = RoomSeed()
        let controller = seed.controller
        var written: [String] = []

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme = .dark,
                           background: KeyPath<Theme, Color> = \.background, grows: Bool = false, zoom: CGFloat = zoom,
                           @ViewBuilder _ view: () -> V) {
            let width = grows ? baseWidth * zoom : baseWidth
            let height = grows ? baseHeight.map { $0 * zoom } : baseHeight
            let content = RoomSnapshotCanvas(width: width, height: height, background: background) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = directory.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        save("new-room-sheet", width: 680, height: nil, grows: true) {
            NewRoomSheet(controller: controller, recentFolders: [seed.folder, NSHomeDirectory() + "/Developer/portfolio-site"],
                         draft: seed.newRoomDraft)
        }
        save("room-team", width: 1180, height: 900) {
            RoomView(controller: controller, engine: seed.team)
        }
        save("room-team-agent-session", width: 1180, height: 900) {
            RoomView(controller: controller, engine: seed.team, initialAgentID: seed.gpt.id)
        }
        save("room-team-plan-approval", width: 1180, height: 900) {
            RoomView(controller: controller, engine: seed.planApproval)
        }
        save("room-debate", width: 1180, height: 900) {
            RoomView(controller: controller, engine: seed.debate)
        }
        save("room-debate-rounds", width: 1180, height: 960) {
            RoomView(controller: controller, engine: seed.debate, initialTab: .rounds)
        }
        save("room-round-table", width: 1180, height: 900) {
            RoomView(controller: controller, engine: seed.roundTable, snapshotDraft: "@")
        }
        save("room-team-narrow", width: 720, height: 700) {
            RoomView(controller: controller, engine: seed.team)
        }
        save("room-solo", width: 1180, height: 700) {
            RoomView(controller: controller, engine: seed.solo, snapshotDraft: "Add a section on remote control")
        }
        save("room-team-light", width: 1180, height: 900, scheme: .light) {
            RoomView(controller: controller, engine: seed.team)
        }
        save("rooms-sidebar-section", width: 260, height: nil, background: \.sidebar, grows: true) {
            RoomsSidebarSection(controller: controller, isShowingRoom: true, onSelect: { _ in })
                .padding(.horizontal, 8 * zoom)
                .padding(.vertical, 12 * zoom)
        }
        save("room-team-zoom-150", width: 1180, height: 900, zoom: zoom * 1.5) {
            RoomView(controller: controller, engine: seed.team)
        }
        print("Rendered \(written.count) room snapshots:")
        for path in written { print(path) }
        return written
    }
}

/// Fixed-size background for a snapshot.
private struct RoomSnapshotCanvas<Content: View>: View {
    let width: CGFloat
    let height: CGFloat?
    let background: KeyPath<Theme, Color>
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .frame(width: width, height: height, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: height == nil)
            .background(theme[keyPath: background])
    }
}

/// Seeded rooms that look like real runs.
@MainActor
struct RoomSeed {
    let controller: RoomsController
    let folder = NSHomeDirectory() + "/Ensemble"
    let opus: AgentSpec
    let gpt: AgentSpec
    let haiku: AgentSpec
    let team: RoomEngine
    let planApproval: RoomEngine
    let debate: RoomEngine
    let roundTable: RoomEngine
    let solo: RoomEngine
    let newRoomDraft: NewRoomDraft

    init() {
        let api = PreviewEngine()
        let store = InMemoryRoomStore()
        let models = PreviewData.seed().models
        let opusRef = ModelRef(providerID: "anthropic", id: "claude-opus-5-5")
        let sonnetRef = ModelRef(providerID: "anthropic", id: "claude-sonnet-5")
        let haikuRef = ModelRef(providerID: "anthropic", id: "claude-haiku-5")
        let gptRef = ModelRef(providerID: "openai", id: "gpt-5.5")
        let grokRef = ModelRef(providerID: "xai", id: "grok-5")
        let start = Date().addingTimeInterval(-1500)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

        let opus = AgentSpec(name: "Opus", model: opusRef, role: "Plans and builds the model layer", colorHex: "#A78BFA", spendingCapUSD: 3)
        let gpt = AgentSpec(name: "GPT", model: gptRef, role: "Builds the views", colorHex: "#34D399")
        let haiku = AgentSpec(name: "Haiku", model: haikuRef, role: "Writes the tests", colorHex: "#60A5FA", spendingCapUSD: 1)
        self.opus = opus
        self.gpt = gpt
        self.haiku = haiku

        // Team, mid-run: one piece approved, one in review, one back with changes.
        var t = RoomState(spec: RoomSpec(title: "Settings screen", directory: folder, agents: [opus, gpt, haiku], mode: .team,
                                         leadAgentID: opus.id, permissionMode: .auto, created: at(0)))
        t.run = 1
        t.phase = .working
        t.task = "Add a Settings screen with an API key field, a model picker and tests."
        t.sessions = [opus.id: "ses_room_opus", gpt.id: "ses_room_gpt", haiku.id: "ses_room_haiku"]
        t.git = GitContext(isRepository: true, baseBranch: "main")
        t.plan = "Settings gets its own view model so the view stays thin. Keys go in the Keychain, never in UserDefaults.\nASSIGN @Opus: SettingsModel.swift, key storage and validation\nASSIGN @GPT: SettingsView.swift, the key field and model picker\nASSIGN @Haiku: SettingsTests.swift, save, load and bad keys"
        t.assignments = [
            Assignment(agentID: opus.id, task: "SettingsModel.swift, key storage and validation", status: .approved, reviewerID: gpt.id,
                       branch: "ensemble/settings-screen/opus", changedFiles: ["Sources/App/SettingsModel.swift"]),
            Assignment(agentID: gpt.id, task: "SettingsView.swift, the key field and model picker", status: .inReview, reviewerID: haiku.id,
                       branch: "ensemble/settings-screen/gpt", changedFiles: ["Sources/App/SettingsView.swift", "Sources/App/ModelPicker.swift"]),
            Assignment(agentID: haiku.id, task: "SettingsTests.swift, save, load and bad keys", status: .changesRequested, reviewerID: opus.id,
                       fixRounds: 1, lastReview: "Add a test for a key with surrounding spaces.", branch: "ensemble/settings-screen/haiku",
                       changedFiles: ["Tests/AppTests/SettingsTests.swift"]),
        ]
        t.usage = [opus.id: Usage(inputTokens: 182_000, outputTokens: 9_400, costUSD: 0.84),
                   gpt.id: Usage(inputTokens: 96_000, outputTokens: 7_100, costUSD: 0.41),
                   haiku.id: Usage(inputTokens: 61_000, outputTokens: 3_900, costUSD: 0.06)]
        t.board = [
            BoardMessage(from: .user, kind: .chat, text: t.task!, date: at(0)),
            BoardMessage(from: .agent(opus.id), kind: .plan, text: "PLAN: " + t.plan!, date: at(1)),
            BoardMessage(from: .agent(opus.id), to: [opus.id], kind: .assignment, text: "Opus: SettingsModel.swift, key storage and validation", date: at(1.2)),
            BoardMessage(from: .agent(opus.id), to: [gpt.id], kind: .assignment, text: "GPT: SettingsView.swift, the key field and model picker", date: at(1.2)),
            BoardMessage(from: .agent(opus.id), to: [haiku.id], kind: .assignment, text: "Haiku: SettingsTests.swift, save, load and bad keys", date: at(1.2)),
            BoardMessage(from: .agent(gpt.id), to: [opus.id], kind: .question, text: "Should the model picker list models without a key, greyed out, or hide them?", date: at(3)),
            BoardMessage(from: .agent(opus.id), to: [gpt.id], kind: .chat, text: "Show them greyed out with \"no key\", so people can see what they could add.", date: at(4)),
            BoardMessage(from: .agent(opus.id), kind: .update, text: "SettingsModel is in. Keys save to the Keychain under `com.coquetteluke.ensemble`, and `validate()` rejects empty keys.\nDONE", date: at(7)),
            BoardMessage(from: .agent(gpt.id), kind: .review, text: "Read `SettingsModel.swift`. Validation and Keychain access look right.\nAPPROVE", date: at(9)),
            BoardMessage(from: .agent(haiku.id), kind: .update, text: "Tests for save, load and an empty key are in `SettingsTests.swift`. All 6 pass.\nDONE", date: at(11)),
            BoardMessage(from: .agent(opus.id), kind: .review, text: "CHANGES: add a test for a key with surrounding spaces. It should be trimmed before saving.", date: at(13)),
            BoardMessage(from: .agent(haiku.id), to: [opus.id], kind: .question, text: "Trimmed, or rejected? The model rejects whitespace-only keys today.", date: at(14)),
            BoardMessage(from: .agent(opus.id), to: [haiku.id], kind: .chat, text: "Trimmed. Only whitespace-only keys are rejected.", date: at(14.5)),
            BoardMessage(from: .agent(gpt.id), kind: .update, text: "SettingsView is done: secure field, Save button, and the model picker with keyless models greyed out.\nDONE", date: at(16)),
        ]
        team = RoomEngine(state: t, api: api, store: store)

        // Team in Ask mode: the plan waits for approval.
        let pOpus = AgentSpec(name: "Opus", model: opusRef, role: "Plans and builds the model layer", colorHex: "#A78BFA", spendingCapUSD: 3)
        let pGPT = AgentSpec(name: "GPT", model: gptRef, role: "Builds the views", colorHex: "#34D399")
        var p = RoomState(spec: RoomSpec(title: "Onboarding", directory: folder, agents: [pOpus, pGPT], mode: .team,
                                         leadAgentID: pOpus.id, permissionMode: .ask, created: at(-60)))
        p.run = 1
        p.phase = .awaitingApproval
        p.pendingDecision = .approvePlan
        p.task = "Add a first-run screen that checks OpenCode is installed and helps add the first key."
        p.sessions = [pOpus.id: "ses_onb_opus", pGPT.id: "ses_onb_gpt"]
        p.plan = "One OnboardingView with three steps: engine check, add a key, pick a default model. The engine check reuses EngineManager.\nASSIGN @Opus: OnboardingModel.swift, the step logic and the engine check\nASSIGN @GPT: OnboardingView.swift, the three step screens"
        p.assignments = [
            Assignment(agentID: pOpus.id, task: "OnboardingModel.swift, the step logic and the engine check"),
            Assignment(agentID: pGPT.id, task: "OnboardingView.swift, the three step screens"),
        ]
        p.usage = [pOpus.id: Usage(inputTokens: 41_000, outputTokens: 1_200, costUSD: 0.19)]
        p.board = [
            BoardMessage(from: .user, kind: .chat, text: p.task!, date: at(-60)),
            BoardMessage(from: .agent(pOpus.id), kind: .plan, text: "PLAN: " + p.plan!, date: at(-59)),
            BoardMessage(from: .room, kind: .notice, text: "The plan is ready. Approve, edit or redo it.", date: at(-59)),
        ]
        planApproval = RoomEngine(state: p, api: api, store: store)

        // Debate with a verdict.
        let grok = AgentSpec(name: "Grok", model: grokRef, role: "Looks for failure cases", colorHex: "#FBBF24")
        let dOpus = AgentSpec(name: "Opus", model: opusRef, role: "Argues for the simplest setup", colorHex: "#A78BFA")
        let dGPT = AgentSpec(name: "GPT", model: gptRef, role: "Argues for scale", colorHex: "#34D399")
        var d = RoomState(spec: RoomSpec(title: "Sync storage", directory: folder, agents: [dOpus, dGPT, grok], mode: .debate,
                                         leadAgentID: dOpus.id, permissionMode: .auto, created: at(-200), debateRounds: 2))
        let question = "Should Ensemble sync rooms through SQLite files in iCloud Drive, or a small Postgres server?"
        d.run = 1
        d.phase = .verdict
        d.task = question
        d.sessions = [dOpus.id: "ses_db_opus", dGPT.id: "ses_db_gpt", grok.id: "ses_db_grok"]
        let args: [(Int, AgentSpec, String)] = [
            (1, dOpus, "SQLite in iCloud Drive. One person, a few devices, and nothing to run or pay for. Room files are small and change rarely."),
            (1, dGPT, "Postgres. Two Macs editing one room at once will conflict in iCloud, and a server gives us shared rooms later for free."),
            (1, grok, "Neither is safe as described. iCloud can hand back a half-synced SQLite file; Postgres adds an always-on server for one user."),
            (2, dOpus, "Grok is right about half-synced files, so write one JSON file per room with atomic saves instead of one SQLite database. Conflicts become per room and rare."),
            (2, dGPT, "Per-room JSON fixes the corruption risk. I still think shared rooms will need a server, but not yet. I can accept files for now."),
            (2, grok, "Per-room files with atomic writes and a conflict copy on mismatch covers the failure cases I raised. I agree."),
        ]
        d.debate = DebateState(question: question, round: 2, totalRounds: 2,
                               arguments: args.map { DebateArgument(round: $0.0, agentID: $0.1.id, text: $0.2) },
                               judgeID: dOpus.id,
                               verdict: "Use one JSON file per room in iCloud Drive, saved atomically.\n\n**Reasons:** one user, a few devices, no server to run or pay for. Per-room files keep conflicts small and rare.\n\n**Strongest dissent:** GPT's point that rooms shared between people will need a server. Revisit when sharing lands.")
        d.usage = [dOpus.id: Usage(inputTokens: 38_000, outputTokens: 2_100, costUSD: 0.22),
                   dGPT.id: Usage(inputTokens: 31_000, outputTokens: 1_800, costUSD: 0.12),
                   grok.id: Usage(inputTokens: 29_000, outputTokens: 1_500, costUSD: 0.07)]
        var debateBoard: [BoardMessage] = [BoardMessage(from: .user, kind: .chat, text: question, date: at(-200))]
        for (i, arg) in args.enumerated() {
            debateBoard.append(BoardMessage(from: .agent(arg.1.id), kind: .argument, round: arg.0, text: arg.2, date: at(-199 + Double(i))))
        }
        debateBoard.append(BoardMessage(from: .agent(dOpus.id), kind: .verdict, text: "VERDICT: " + d.debate!.verdict!, date: at(-190)))
        d.board = debateBoard
        debate = RoomEngine(state: d, api: api, store: store)

        // Round table: a reviewer offers to take over.
        let sonnet = AgentSpec(name: "Sonnet", model: sonnetRef, role: "Reviews and keeps it simple", colorHex: "#F472B6")
        let rGPT = AgentSpec(name: "GPT", model: gptRef, role: "Builds", colorHex: "#34D399")
        var r = RoomState(spec: RoomSpec(title: "Rate limiter", directory: NSHomeDirectory() + "/Developer/api-server", agents: [rGPT, sonnet],
                                         mode: .roundTable, leadAgentID: rGPT.id, permissionMode: .ask, created: at(-400)))
        r.run = 1
        r.phase = .building
        r.task = "Add a token bucket rate limiter to the API, 60 requests a minute per key."
        r.sessions = [rGPT.id: "ses_rt_gpt", sonnet.id: "ses_rt_sonnet"]
        var rt = RoundTableState(order: [rGPT.id, sonnet.id])
        rt.round = 2
        rt.agreed = [rGPT.id, sonnet.id]
        rt.plan = "Token bucket per API key in memory, refill 1 token a second up to 60. Middleware returns 429 with Retry-After."
        rt.planAuthorID = rGPT.id
        rt.builderID = rGPT.id
        rt.buildTurns = 2
        rt.reviews = [sonnet.id: .takeover("The refill math is off by one second, and it has been wrong twice. I can fix it faster.")]
        rt.pendingTakeoverID = sonnet.id
        r.roundTable = rt
        r.plan = rt.plan
        r.pendingDecision = .takeover(agentID: sonnet.id)
        r.usage = [rGPT.id: Usage(inputTokens: 88_000, outputTokens: 6_300, costUSD: 0.47),
                   sonnet.id: Usage(inputTokens: 52_000, outputTokens: 2_400, costUSD: 0.18)]
        r.board = [
            BoardMessage(from: .user, kind: .chat, text: r.task!, date: at(-400)),
            BoardMessage(from: .agent(rGPT.id), kind: .chat, text: "PLAN: token bucket per API key in memory, refill 1 token a second up to 60. Middleware returns 429 with Retry-After.", date: at(-399)),
            BoardMessage(from: .agent(sonnet.id), kind: .chat, text: "Keep the buckets in an actor so the middleware stays thread safe.\nAGREE", date: at(-398)),
            BoardMessage(from: .room, kind: .notice, text: "Everyone agreed on the plan.", date: at(-398)),
            BoardMessage(from: .room, kind: .notice, text: "GPT builds; the others review each step.", date: at(-398)),
            BoardMessage(from: .agent(rGPT.id), kind: .update, text: "Added `RateLimiter` (an actor) and `RateLimitMiddleware`. Requests over the limit get 429.", date: at(-390)),
            BoardMessage(from: .agent(sonnet.id), kind: .review, text: "CHANGES: Retry-After is always 60. It should be the seconds until the next token.", date: at(-388)),
            BoardMessage(from: .agent(rGPT.id), kind: .update, text: "Retry-After now uses the time until the next refill.", date: at(-384)),
            BoardMessage(from: .agent(sonnet.id), kind: .review, text: "TAKEOVER\nThe refill math is off by one second, and it has been wrong twice. I can fix it faster.", date: at(-382)),
            BoardMessage(from: .room, kind: .notice, text: "Sonnet offers to take over building from GPT. Accept or reject.", date: at(-382)),
        ]
        roundTable = RoomEngine(state: r, api: api, store: store)

        // Solo.
        let soloAgent = AgentSpec(name: "Sonnet", model: sonnetRef, colorHex: "#F472B6")
        var s = RoomState(spec: RoomSpec(title: "Write the README", directory: folder, agents: [soloAgent], mode: .solo,
                                         leadAgentID: soloAgent.id, permissionMode: .acceptEdits, created: at(-600)))
        s.run = 1
        s.phase = .finished
        s.sessions = [soloAgent.id: "ses_solo_sonnet"]
        s.usage = [soloAgent.id: Usage(inputTokens: 22_000, outputTokens: 2_600, costUSD: 0.09)]
        s.board = [
            BoardMessage(from: .user, kind: .chat, text: "Write a README with install steps and a short feature list.", date: at(-600)),
            BoardMessage(from: .agent(soloAgent.id), kind: .chat, text: "The README is in place:\n\n- **Install:** Homebrew for OpenCode, then the app from Releases.\n- **Features:** rooms, the Session Hub, the iPhone remote and per-agent spending caps.\n\nI kept it short and linked to `docs/DESIGN.md` for the details.", date: at(-598)),
        ]
        solo = RoomEngine(state: s, api: api, store: store)

        // The controller with everything seeded.
        controller = RoomsController(api: api, store: store, git: nil)
        let haikuPrompt = PermissionRequest(id: "perm_room_haiku", sessionID: "ses_room_haiku", kind: "shell",
                                            title: "swift test --filter SettingsTests",
                                            detail: "Runs the settings tests in Haiku's worktree.", created: at(17))
        let gptTranscript = AgentTranscript(sessionID: "ses_room_gpt", agentID: gpt.id, items: [
            .notice(id: "n1", text: "[Room] The plan is approved. Start your piece now. Your assignment: SettingsView.swift, the key field and model picker"),
            .agentText(id: "a1", text: "I'll build the view in my worktree, starting from the model Opus is writing.", agentID: gpt.id, streaming: false),
            .tool(ToolCallInfo(id: "t1", name: "read", title: "Sources/App/SettingsModel.swift", status: .succeeded)),
            .agentText(id: "a2", text: "@Opus Should the model picker list models without a key, greyed out, or hide them?", agentID: gpt.id, streaming: false),
            .notice(id: "n2", text: "[Room] Opus (anthropic/claude-opus-5.5) to you: Show them greyed out with \"no key\", so people can see what they could add."),
            .tool(ToolCallInfo(id: "t2", name: "edit", title: "Sources/App/SettingsView.swift", status: .succeeded,
                               diff: "@@ -1,4 +1,9 @@\n struct SettingsView: View {\n-    var body: some View { EmptyView() }\n+    @Bindable var model: SettingsModel\n+    var body: some View {\n+        Form {\n+            SecureField(\"API key\", text: $model.key)\n+            ModelPicker(selection: $model.model)\n+        }\n+    }\n }")),
            .tool(ToolCallInfo(id: "t3", name: "shell", title: "swift build", status: .succeeded, outputPreview: "Build complete! (4.12s)")),
            .agentText(id: "a3", text: "SettingsView is done: secure field, Save button, and the model picker with keyless models greyed out.\n\nDONE", agentID: gpt.id, streaming: false),
        ], loaded: true)
        controller.seed(engines: [solo, roundTable, debate, planApproval, team], models: models,
                        permissions: [haikuPrompt], transcripts: [gptTranscript])
        controller.selectedRoomID = team.state.id
        controller.activityOverride = [opus.id: .working]
        controller.liveTextOverride = [opus.id: "Reading `SettingsTests.swift` again to check the trimming case before I review the next round."]

        var draft = NewRoomDraft()
        draft.title = "Settings screen"
        draft.directory = folder
        draft.mode = .team
        draft.agents = [
            NewRoomDraft.Agent(id: opus.id, name: "Opus", modelID: opusRef.description, role: "Plans and builds the model layer", colorHex: "#A78BFA", cap: "3.00"),
            NewRoomDraft.Agent(id: gpt.id, name: "GPT", modelID: gptRef.description, role: "Builds the views", colorHex: "#34D399"),
            NewRoomDraft.Agent(id: haiku.id, name: "Haiku", modelID: haikuRef.description, role: "Writes the tests", colorHex: "#60A5FA", cap: "1.00"),
        ]
        draft.lead = .agent(opus.id)
        draft.permissionMode = .auto
        newRoomDraft = draft
    }
}
