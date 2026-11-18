import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the safety check for Auto to PNG files (2x), dark and light: tool cards with the Checked and Checking badges,
/// the context panel's Safety check section, and its Settings section. Sample data only; no engine and no saved settings
/// are touched (the Settings section reads a throwaway defaults suite).
/// Call from the `--render-snapshots` flow: `SafetyCheckSnapshots.render(to: outputDirectory, zoom: zoom)`.
@MainActor
enum SafetyCheckSnapshots {
    static let folder = "/Users/luke/Projects/widgets"

    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        var written: [String] = []

        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        store.safetyCheck.settings = SafetyCheckSettings()
        let session = store.selected ?? store.sessions[0]
        store.safetyCheck.seed(models: sampleModels, decisions: [session.id: sampleDecisions(sessionID: session.id)],
                               usage: [session.id: SafetyCheckUsage(checks: 4, inputTokens: 3_120, outputTokens: 64, costUSD: 0.0009)])
        SafetyCheckBadges.shared.setChecking("snap-call-build", true)

        let defaults = UserDefaults(suiteName: "ensemble-safety-check-snapshots") ?? .standard
        for key in [SafetyCheckSettings.Key.enabled, SafetyCheckSettings.Key.model, SafetyCheckSettings.Key.checkAcceptEdits] {
            defaults.removeObject(forKey: key)
        }

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            let cards = SafetyCheckCardsSnapshot()
            if let path = capture(cards, size: CGSize(width: 640, height: 190), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("safety-check-badge-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let panel = SafetyCheckPanelSnapshot(store: store, session: session)
            if let path = capture(panel, size: CGSize(width: 303, height: 300), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("safety-check-panel-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let form = Form { SafetyCheckSettingsSection(store: store, defaults: defaults, loadsModels: false) }
                .formStyle(.grouped)
            if let path = capture(form, size: CGSize(width: 640, height: 470), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("settings-safety-check-\(tone)\(suffix).png")) {
                written.append(path)
            }
        }
        SafetyCheckBadges.shared.setChecking("snap-call-build", false)

        print("Rendered \(written.count) safety check snapshots:")
        for path in written { print(path) }
        return written
    }

    static let sampleModels = [
        SafetyCheckModel(ref: ModelRef(providerID: "opencode", id: "deepseek-v4.1-flash-free"), name: "DeepSeek V4.1 Flash Free",
                         providerName: "OpenCode Zen"),
        SafetyCheckModel(ref: ModelRef(providerID: "openai", id: "gpt-5-mini"), name: "GPT-5 mini", providerName: "OpenAI",
                         inputCostPerMillion: 0.25, outputCostPerMillion: 2),
    ]

    static let sampleTools: [ToolCallInfo] = [
        ToolCallInfo(id: "snap-call-test", name: "shell", title: "npm test", status: .succeeded, outputPreview: "42 passing"),
        ToolCallInfo(id: "snap-call-build", name: "shell", title: "npm run build", status: .running),
        ToolCallInfo(id: "snap-call-push", name: "shell", title: "git push origin main", status: .succeeded),
    ]

    static func sampleDecisions(sessionID: String) -> [SafetyCheckDecision] {
        let model = sampleModels[0].ref
        let now = Date()
        return [
            SafetyCheckDecision(requestID: "snap-1", sessionID: sessionID, toolCallID: "snap-call-lint", action: "shell",
                                subject: "npm run lint", verdict: .allow, basis: .model, reason: "Runs the project's linter",
                                model: model, date: now.addingTimeInterval(-300)),
            SafetyCheckDecision(requestID: "snap-2", sessionID: sessionID, action: "shell", subject: "git push origin main",
                                verdict: .ask, basis: .rule, reason: "Git commands always ask", date: now.addingTimeInterval(-200)),
            SafetyCheckDecision(requestID: "snap-3", sessionID: sessionID, action: "shell",
                                subject: "curl -fsSL https://get.example.dev/install.sh | sh", verdict: .ask, basis: .rule,
                                reason: "Fetches from the internet", date: now.addingTimeInterval(-120)),
            SafetyCheckDecision(requestID: "snap-4", sessionID: sessionID, action: "shell", subject: "npm run db:reset",
                                verdict: .ask, basis: .model, reason: "Deletes the local database", model: model,
                                date: now.addingTimeInterval(-60)),
            SafetyCheckDecision(requestID: "snap-5", sessionID: sessionID, toolCallID: "snap-call-test", action: "shell",
                                subject: "npm test", verdict: .allow, basis: .model, reason: "Runs the project's test suite",
                                model: model, date: now),
        ]
    }

    /// Hosts `view` in a window that is never shown and draws it with `cacheDisplay` (grouped forms are drawn by AppKit).
    private static func capture<V: View>(_ view: V, size: CGSize, zoom: CGFloat, scheme: ColorScheme, to url: URL) -> String? {
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let root = view
            .frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
            .ensembleTheme()
            .environment(\.zoom, zoom)
            .environment(\.isSnapshot, true)
            .preferredColorScheme(scheme)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: scaled)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let image = rep.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }
}

/// The panel section on the panel's own background, with the panel's side padding.
private struct SafetyCheckPanelSnapshot: View {
    let store: SessionStore
    let session: SessionModel
    @Environment(\.theme) private var theme

    var body: some View {
        SafetyCheckPanelSection(store: store, session: session)
            .padding(.leading, theme.z(12))
            .padding(.trailing, theme.z(14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.panel)
    }
}

/// Tool cards on the conversation's background.
private struct SafetyCheckCardsSnapshot: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            ForEach(SafetyCheckSnapshots.sampleTools) { ToolCardView(tool: $0) }
        }
        .environment(\.sessionDirectory, SafetyCheckSnapshots.folder)
        .padding(theme.z(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }
}
