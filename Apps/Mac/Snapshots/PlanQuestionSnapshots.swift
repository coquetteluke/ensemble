import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots for plans and questions: a plan card with two line comments (one being written), answered plan cards, the
/// question card docked above the composer, a two-question card with checkboxes and a typed answer, the iPhone's
/// question card, and the mode menu with Plan. Each in dark and light at the requested zoom. Called from
/// `SnapshotRenderer.run`.
@MainActor
enum PlanQuestionSnapshots {
    static let plan = """
    # Add a usage ring next to the composer

    Show the subscription's five-hour and weekly use as a ring beside the send button, like the reference app.

    ## Changes
    1. Add `UsageRing` to `Apps/Mac/Composer/` that draws both limits as two arcs.
    2. Read the limits from `store.planLimits` and refresh them after every turn.
    3. Show the reset time in the ring's tooltip.

    ## Checks
    - Snapshot the ring at 0%, 60% and 95% in dark and light.
    - Run `swift test --filter PlanLimits`.
    """

    static let planID = "plan_usage_ring"
    static let questionID = "question_ring_style"

    static func render(to directory: URL, zoom: CGFloat) {
        var seed = PreviewData.seed()
        let sessionID = PreviewData.mainSessionID
        seed.permissions.removeAll { $0.sessionID == sessionID }
        seed.activities[sessionID] = .waitingForPermission
        seed.modes[sessionID] = .plan
        let planRequest = PermissionRequest(id: planID, sessionID: sessionID, kind: InteractionKind.plan,
                                            title: "Add a usage ring next to the composer",
                                            plan: PlanProposal(markdown: plan, filePath: "~/.claude/plans/usage-ring.md",
                                                               proceedMode: .acceptEdits))
        let question = PermissionRequest(
            id: questionID, sessionID: sessionID, kind: InteractionKind.question, title: "Which limit should the outer ring show?",
            questions: [AgentQuestion(id: "Which limit should the outer ring show?", header: "Ring",
                                      text: "Which limit should the outer ring show?",
                                      options: [.init(label: "Five-hour limit", detail: "Changes most often, so it is easiest to watch"),
                                                .init(label: "Weekly limit", detail: "The one that stops work for days when it runs out"),
                                                .init(label: "Whichever is closer to full")],
                                      multiSelect: false, allowsOther: true)])
        seed.permissions = [question]
        seed.transcripts[sessionID] = [
            .user(id: "u-plan", text: "Plan a usage ring for the composer before touching anything", date: Date().addingTimeInterval(-300)),
            .agentText(id: "a-plan", text: "I read the composer and the plan-limits code. Here is the plan.", agentID: nil, streaming: false),
            .permission(planRequest),
        ]
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0))
        store.seed(seed)
        store.planCommentDrafts[planID] = [
            4: "Put the ring inside the status line instead, so the composer stays as it is.",
            7: "",
        ]
        let window = WindowState()
        guard let session = store.session(sessionID) else { return }

        // Answered cards, as they stay in the transcript.
        let proceeded = PermissionRequest(id: "plan_done", sessionID: sessionID, kind: InteractionKind.plan, title: "Plan",
                                          plan: PlanProposal(markdown: plan, proceedMode: .acceptEdits))
        let kept = PermissionRequest(id: "plan_kept", sessionID: sessionID, kind: InteractionKind.plan, title: "Plan",
                                     plan: PlanProposal(markdown: plan, proceedMode: .acceptEdits))
        let answered = PermissionRequest(
            id: "question_done", sessionID: sessionID, kind: InteractionKind.question, title: question.title,
            questions: question.questions)

        // Two questions, the second with checkboxes and a typed answer.
        let multi = PermissionRequest(
            id: "question_multi", sessionID: sessionID, kind: InteractionKind.question, title: "Ring colours",
            questions: [question.questions![0],
                        AgentQuestion(id: "Which states should change the ring's colour?", header: "Colours",
                                      text: "Which states should change the ring's colour?",
                                      options: [.init(label: "Over 80% used"), .init(label: "Limit reached"), .init(label: "Resetting soon")],
                                      multiSelect: true, allowsOther: true)])

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("plan-card-\(tone)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                TranscriptList(items: session.items, resolutions: session.resolutions, agents: store.agents)
                    .environment(\.interactionStore, store)
                    .environment(\.transcriptActions, TranscriptActions(shortcutPermissionID: planID))
                    .padding(28)
            }
            written += save("plan-card-answered-\(tone)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                AnsweredCards(store: store, proceeded: proceeded, kept: kept, answered: answered)
                    .padding(28)
            }
            written += save("question-docked-\(tone)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                VStack(alignment: .leading, spacing: 0) {
                    ComposerView(store: store, session: session, window: window, snapshotDraft: "")
                    StatusLine(store: store, session: session, window: window)
                }
                .environment(\.interactionStore, store)
                .padding(24)
            }
            written += save("question-two-steps-\(tone)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                QuestionCardView(request: multi, step: 1,
                                 selections: ["Which states should change the ring's colour?": ["Over 80% used", "Limit reached"]],
                                 others: ["Which states should change the ring's colour?": "Grey while offline"],
                                 onAnswer: { _ in }, onDecline: {})
                    .padding(24)
            }
            written += save("iphone-question-\(tone)", to: directory, width: 390, zoom: zoom, scheme: scheme) {
                PhoneFrame {
                    QuestionCardView(request: question, onAnswer: { _ in }, onDecline: {})
                }
            }
            written += save("mode-menu-plan-\(tone)", to: directory, width: 340, zoom: zoom, scheme: scheme) {
                VStack(alignment: .leading, spacing: 16) {
                    ModeMenuContent(current: .plan, planSupport: .supported) { _ in }
                    ModeMenuContent(current: .ask,
                                    planSupport: .unsupported(reason: "OpenCode (ACP) has no plan mode.")) { _ in }
                }
                .padding(20)
            }
        }
        for path in written { print(path) }
    }

    /// Cards after Proceed, Keep planning and an answered question.
    private struct AnsweredCards: View {
        let store: SessionStore
        let proceeded: PermissionRequest
        let kept: PermissionRequest
        let answered: PermissionRequest

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                PlanCardView(request: proceeded, resolution: .allowedOnce)
                PlanCardView(request: kept, resolution: .rejected, expanded: true)
                QuestionRecordView(request: answered, resolution: .allowedOnce)
            }
            .environment(\.interactionStore, outcomesStore)
        }

        /// A store that knows how the three were resolved.
        private var outcomesStore: SessionStore {
            let copy = SessionStore(engine: PreviewEngine(seed: StoreSeed(), delayScale: 0))
            copy.recordOutcomesForSnapshots([
                proceeded.id: .proceeded(.acceptEdits),
                kept.id: .keptPlanning(commentCount: 2),
                answered.id: .answered([AgentQuestionAnswer(questionID: answered.questions![0].id, selected: ["Weekly limit"])]),
            ])
            return copy
        }
    }

    /// An iPhone-width screen with the phone's slightly larger type.
    private struct PhoneFrame<Content: View>: View {
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            var phone = theme
            phone.scale = theme.scale * 1.15
            return VStack(alignment: .leading, spacing: 12) {
                Text("Build the context panel")
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                content.environment(\.theme, phone)
            }
            .padding(16)
            .background(theme.background)
        }
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let content = Canvas(width: width * zoom) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width * zoom, height: nil)
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
