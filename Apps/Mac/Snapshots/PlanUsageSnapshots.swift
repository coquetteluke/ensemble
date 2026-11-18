import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of both subscription plans, in dark and light at the requested zoom:
/// - the usage popover in a Gemini session (Google AI plan first) and in a Claude session (Claude plan first);
/// - the popover in a Gemini session when a Gemini limit is used up, and when agy reports no limits;
/// - the status line's plan ring in a Claude session and in a Gemini session (Gemini's own limits, never Claude's);
/// - the Usage screen with both plan cards.
/// Called from `SnapshotRenderer.run`. Sample data only: nothing runs agy or claude.
@MainActor
enum PlanUsageSnapshots {
    static let geminiID = "ses_plan_gemini"
    static let claudeID = "ses_plan_claude"

    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let now = Date()
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        let window = WindowState()
        let tracker = UsageTracker(storage: InMemoryUsageStorage(), now: { now })
        tracker.attach(to: store, sampling: false)
        tracker.seed(UsageSamples.ledger(now: now), caps: UsageSamples.caps)
        tracker.setBilling(UsageSamples.billing)

        let folder = NSHomeDirectory() + "/Ensemble"
        let gemini = SessionModel(info: EngineSession(id: geminiID, title: "Port the parser to Gemini", directory: folder,
                                                      model: ModelRef(providerID: "antigravity", id: "gemini-4-carbon", variant: "medium")))
        let claude = SessionModel(info: EngineSession(id: claudeID, title: "Build the context panel", directory: folder,
                                                      model: ModelRef(providerID: "claude-code", id: "claude-opus-5-5")))
        let usage = Usage(inputTokens: 21_400, outputTokens: 2_600, reasoningTokens: 900)
        let claudeLimits = UsageSamples.planLimits(now: now)
        func plans(_ google: AntigravityPlanStatus, tokens: Int? = nil) -> PlanUsageSnapshot {
            PlanUsageSnapshot(plans: [.claude, .googleAI], claude: claudeLimits, google: google, googleTokensToday: tokens, now: now)
        }
        let both = plans(GooglePlanSamples.status(now: now))

        for scheme in [ColorScheme.dark, .light] {
            let tone = (scheme == .dark ? "dark" : "light") + suffix
            written += save("usage-popover-gemini-\(tone)", to: directory, width: 240, zoom: zoom, scheme: scheme) {
                UsagePopover(usage: usage, title: gemini.title, store: store, session: gemini, planSnapshot: both) {}
            }
            written += save("usage-popover-claude-\(tone)", to: directory, width: 240, zoom: zoom, scheme: scheme) {
                UsagePopover(usage: Usage(inputTokens: 412_000, outputTokens: 18_400, reasoningTokens: 6_100, cacheReadTokens: 1_200_000,
                                          costUSD: 2.84),
                             title: claude.title, store: store, session: claude, planSnapshot: both) {}
            }
            written += save("usage-popover-gemini-limit-\(tone)", to: directory, width: 240, zoom: zoom, scheme: scheme) {
                UsagePopover(usage: usage, title: gemini.title, store: store, session: gemini,
                             planSnapshot: plans(GooglePlanSamples.limited(now: now))) {}
            }
            written += save("usage-popover-gemini-unreported-\(tone)", to: directory, width: 240, zoom: zoom, scheme: scheme) {
                UsagePopover(usage: usage, title: gemini.title, store: store, session: gemini,
                             planSnapshot: plans(GooglePlanSamples.notReported(), tokens: 1_240_000)) {}
            }
            written += save("status-line-plans-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                StatusLinePlans(store: store, window: window, now: now)
            }
            written += save("usage-screen-plans-\(tone)", to: directory, width: 900, zoom: zoom, scheme: scheme) {
                UsageScreen(store: store, tracker: tracker, planLimits: claudeLimits, googlePlan: GooglePlanSamples.status(now: now))
            }
        }
        print("Rendered \(written.count) plan usage snapshots:")
        for path in written { print(path) }
        return written
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = Canvas(width: w) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
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

/// The status line in a Claude session (the Claude plan's ring) and in a Gemini session (the Gemini models' own
/// five-hour and weekly limits), each under a caption.
private struct StatusLinePlans: View {
    let store: SessionStore
    let window: WindowState
    let now: Date
    @Environment(\.theme) private var theme

    var body: some View {
        let claudeMeter = UsageSamples.planLimits(now: now).map(PlanLimitMeter.init(limits:))
        let google = GooglePlanSamples.status(now: now)
        let geminiMeter = google.meter(forModel: "gemini-4-carbon")
        let limitedMeter = GooglePlanSamples.limited(now: now).meter(forModel: "gemini-4-carbon")
        VStack(alignment: .leading, spacing: theme.z(14)) {
            if let session = store.selected {
                row("Claude session", session: session, meter: claudeMeter, plan: .claude)
                row("Gemini session", session: session, meter: geminiMeter, plan: .googleAI)
                row("Gemini session, five-hour limit used up", session: session, meter: limitedMeter, plan: .googleAI)
                VStack(alignment: .leading, spacing: theme.z(4)) {
                    caption("Tooltip in the Gemini session")
                    Text(PlanLimitStatusItem.tooltip(geminiMeter, plan: .googleAI, group: google.usage?.group(forModel: "gemini-4-carbon")?.label,
                                                     now: now))
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(theme.z(16))
    }

    private func row(_ title: String, session: SessionModel, meter: PlanLimitMeter?, plan: SubscriptionPlan) -> some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            caption(title)
            StatusLine(store: store, session: session, window: window, planMeter: meter, planMeterPlan: plan)
                .background(RoundedRectangle(cornerRadius: theme.z(6)).strokeBorder(theme.border.opacity(0.6)))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 11, weight: .medium))
            .foregroundStyle(theme.textTertiary)
    }
}
