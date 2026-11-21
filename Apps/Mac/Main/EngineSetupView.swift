import SwiftUI
import AppKit
import EnsembleKit

/// First launch on a Mac without the engine. One button downloads OpenCode from its own releases, checks it and
/// installs it (`EngineInstaller`); nothing is downloaded until that button is pressed. The screen also looks on disk
/// every few seconds, so it moves on when OpenCode arrives some other way (the installer app, Homebrew).
struct EngineSetupView: View {
    enum Install: Equatable {
        case idle
        case working(EngineInstaller.Stage)
        case failed(String)
    }

    let retry: () -> Void
    /// Fixed states for snapshots. Nil looks on disk.
    private let fixedSetup: EngineSetup?

    @Environment(\.theme) private var theme
    @State private var setup: EngineSetup
    @State private var install: Install
    @State private var copied = false
    @State private var checkedWithoutLuck = false

    /// `fixedSetup` and `install` are for snapshots; the app passes neither.
    init(retry: @escaping () -> Void, fixedSetup: EngineSetup? = nil, install: Install = .idle) {
        self.retry = retry
        self.fixedSetup = fixedSetup
        _setup = State(initialValue: fixedSetup ?? EngineSetup.detect())
        _install = State(initialValue: install)
    }

    private var isWorking: Bool { if case .working = install { true } else { false } }

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
                Text("Ensemble runs its agents through OpenCode, a free, open-source program, and OpenCode is not on this Mac yet.")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            installCard
            if setup.homebrewInstalled { homebrewRow }
        }
        .frame(maxWidth: theme.z(560), alignment: .leading)
        .padding(theme.z(40))
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: theme.z(12)) {
            switch install {
            case .idle, .failed:
                Text("Ensemble downloads OpenCode (about 110 MB) from OpenCode's own releases, checks that it is the file OpenCode published and signed, and puts it in ~/.opencode/bin.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = install {
                    Text(message)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: theme.z(10)) {
                    Button(install == .idle ? "Install the engine" : "Try again", action: installEngine)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("Check again", action: checkAgain)
                        .buttonStyle(SecondaryButtonStyle())
                    if checkedWithoutLuck {
                        Text("OpenCode is not installed yet.")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            case .working(let stage):
                Text(Self.label(for: stage))
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.track)
                        Capsule().fill(theme.accent).frame(width: max(theme.z(8), proxy.size.width * Self.fraction(for: stage)))
                    }
                }
                .frame(height: theme.z(6))
                .accessibilityLabel("Engine install progress")
                .accessibilityValue("\(Int(Self.fraction(for: stage) * 100)) percent")
            }
        }
        .padding(theme.z(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    /// Only shown to people who have Homebrew: the same engine, installed their way.
    private var homebrewRow: some View {
        HStack(spacing: theme.z(8)) {
            Text("Or with Homebrew:")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text(EngineSetup.openCodeCommand)
                .font(theme.font(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy", action: copyCommand)
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Copy the Homebrew command")
        }
    }

    static func label(for stage: EngineInstaller.Stage) -> String {
        switch stage {
        case .finding: "Finding the newest OpenCode"
        case .downloading(let fraction): "Downloading OpenCode, \(Int(fraction * 100))%"
        case .checking: "Checking the download"
        case .installing: "Installing"
        }
    }

    static func fraction(for stage: EngineInstaller.Stage) -> Double {
        switch stage {
        case .finding: 0.03
        case .downloading(let fraction): 0.05 + 0.8 * fraction
        case .checking: 0.9
        case .installing: 0.97
        }
    }

    private func installEngine() {
        guard !isWorking else { return }
        install = .working(.finding)
        checkedWithoutLuck = false
        Task {
            do {
                try await EngineInstaller().install { stage in
                    Task { @MainActor in
                        if case .working = install { install = .working(stage) }
                    }
                }
                install = .idle
                setup = EngineSetup.detect()
                retry()
            } catch {
                install = .failed(error.localizedDescription)
            }
        }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EngineSetup.openCodeCommand, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
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
            guard !isWorking else { continue }
            let now = EngineSetup.detect()
            if now != setup { setup = now }
            if now.openCodeInstalled {
                retry()
                return
            }
        }
    }
}
