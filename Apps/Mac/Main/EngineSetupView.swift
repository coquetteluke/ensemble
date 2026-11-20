import SwiftUI
import AppKit
import EnsembleKit

/// First launch on a Mac without the engine: the commands that install it, a button that opens Terminal, and
/// Check again. It also looks on disk every few seconds, so the window moves on as soon as the install finishes.
/// Ensemble never downloads or runs an installer itself; the person runs the commands.
struct EngineSetupView: View {
    let retry: () -> Void
    /// A fixed state for snapshots. Nil looks on disk.
    private let fixedSetup: EngineSetup?

    @Environment(\.theme) private var theme
    @State private var setup: EngineSetup
    /// Homebrew was missing when the screen opened, so its step stays listed (ticked once it is installed).
    @State private var includeHomebrew: Bool
    @State private var copied: EngineSetup.Step.Kind?
    @State private var checkedWithoutLuck = false

    /// `fixedSetup` and `includeHomebrew` are for snapshots; the app passes neither.
    init(retry: @escaping () -> Void, fixedSetup: EngineSetup? = nil, includeHomebrew: Bool? = nil) {
        self.retry = retry
        self.fixedSetup = fixedSetup
        let now = fixedSetup ?? EngineSetup.detect()
        _setup = State(initialValue: now)
        _includeHomebrew = State(initialValue: includeHomebrew ?? !now.homebrewInstalled)
    }

    private var steps: [EngineSetup.Step] { setup.steps(includeHomebrew: includeHomebrew) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .task { await watchForTheEngine() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.z(18)) {
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Text("Install the engine")
                    .font(theme.font(size: 20, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Ensemble runs its agents through OpenCode, and OpenCode is not on this Mac yet. "
                     + (steps.count == 1 ? "Run this command in Terminal." : "Run these commands in Terminal, one at a time.")
                     + " Ensemble continues by itself once OpenCode is installed.")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepCard(step, number: steps.count > 1 ? index + 1 : nil)
            }
            HStack(spacing: theme.z(10)) {
                Button("Open Terminal", action: openTerminal)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Check again", action: checkAgain)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                if checkedWithoutLuck {
                    Text("OpenCode is not installed yet.")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: theme.z(560), alignment: .leading)
        .padding(theme.z(40))
    }

    private func stepCard(_ step: EngineSetup.Step, number: Int?) -> some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(8)) {
                Text(number.map { "\($0). \(step.title)" } ?? step.title)
                    .font(theme.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if step.done {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.success)
                }
            }
            Text(step.note)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: theme.z(10)) {
                Text(step.command)
                    .font(theme.font(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied == step.kind ? "Copied" : "Copy") { copy(step) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Copy the command for \(step.title)")
            }
            .padding(theme.z(10))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
        }
        .padding(theme.z(14))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .opacity(step.done ? 0.6 : 1)
    }

    private func copy(_ step: EngineSetup.Step) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(step.command, forType: .string)
        copied = step.kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == step.kind { copied = nil }
        }
    }

    private func openTerminal() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    private func checkAgain() {
        setup = EngineSetup.detect()
        checkedWithoutLuck = !setup.openCodeInstalled
        retry()
    }

    /// Looks every three seconds. When OpenCode appears it asks the engine to start, once.
    private func watchForTheEngine() async {
        guard fixedSetup == nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            let now = EngineSetup.detect()
            if now != setup { setup = now }
            if now.openCodeInstalled {
                retry()
                return
            }
        }
    }
}
