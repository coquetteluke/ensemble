import SwiftUI

/// The installer's colours: Ensemble's dark palette. The window is always dark, like the app's default.
enum InstallerColors {
    static let background = Color(red: 0x1D / 255, green: 0x1C / 255, blue: 0x1B / 255)
    static let panel = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255)
    static let raised = Color(red: 0x25 / 255, green: 0x24 / 255, blue: 0x23 / 255)
    static let code = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)
    static let border = Color(red: 0x32 / 255, green: 0x31 / 255, blue: 0x30 / 255)
    static let text = Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEC / 255)
    static let secondary = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA0 / 255)
    static let accent = Color(red: 0x8B / 255, green: 0x7C / 255, blue: 0xF6 / 255)
    static let success = Color(red: 0x5B / 255, green: 0xC8 / 255, blue: 0x8A / 255)
    static let danger = Color(red: 0xF0 / 255, green: 0x6A / 255, blue: 0x6A / 255)
}

struct InstallerView: View {
    let model: InstallerModel
    static let size = CGSize(width: 780, height: 500)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(InstallerColors.border).frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 28)
                .background(InstallerColors.background)
        }
        // The window is a little taller than the content (its hidden title bar), so the two columns stretch to fill it.
        .frame(minWidth: Self.size.width, maxWidth: .infinity, minHeight: Self.size.height, maxHeight: .infinity)
        .foregroundStyle(InstallerColors.text)
        .task(id: model.phase == .engine) { await model.watchForTheEngine() }
    }

    // MARK: Left side: the app and the three steps

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: model.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.top, 40)
            Text("Ensemble")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 10)
            if let version = model.version {
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(InstallerColors.secondary)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 14) {
                stepRow(1, "Install the app", state: appState)
                stepRow(2, "Set up the engine", state: engineState)
                stepRow(3, "Open Ensemble", state: model.phase == .done ? .current : .waiting)
            }
            .padding(.top, 34)
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(width: 236, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(InstallerColors.panel)
    }

    private enum StepState { case waiting, current, done }

    private var appState: StepState {
        switch model.phase {
        case .welcome, .installing, .failed: .current
        case .engine, .done: .done
        }
    }

    private var engineState: StepState {
        switch model.phase {
        case .engine: .current
        case .done: model.setup.openCodeInstalled ? .done : .waiting
        default: .waiting
        }
    }

    private func stepRow(_ number: Int, _ title: String, state: StepState) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state == .done ? InstallerColors.success : (state == .current ? InstallerColors.accent : Color.clear))
                    .overlay(Circle().strokeBorder(state == .waiting ? InstallerColors.border : Color.clear, lineWidth: 1.5))
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(InstallerColors.panel)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state == .current ? Color.white : InstallerColors.secondary)
                }
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 13, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? InstallerColors.secondary : InstallerColors.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : (state == .current ? "Current step" : "Not started"))
    }

    // MARK: Right side: one page per phase

    @ViewBuilder private var page: some View {
        switch model.phase {
        case .welcome: welcome
        case .installing(let stage): installing(stage)
        case .engine: engine
        case .done: done
        case .failed(let message): failed(message)
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(detail)
                .font(.system(size: 13.5))
                .foregroundStyle(InstallerColors.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Install Ensemble", "Code with several AI models at once. This installer copies Ensemble to your Mac and helps you set up the engine it runs on.")
            VStack(alignment: .leading, spacing: 0) {
                fact("Installs", model.title)
                Rectangle().fill(InstallerColors.border).frame(height: 1)
                fact("Into", model.destinationName)
                if let old = model.replacingVersion {
                    Rectangle().fill(InstallerColors.border).frame(height: 1)
                    fact("Replaces", "Ensemble \(old)" + (model.appIsOpen ? ", which is open and will be quit" : ""))
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(InstallerColors.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(InstallerColors.border, lineWidth: 1))
            Spacer()
            HStack {
                Spacer()
                Button(model.replacingVersion == nil ? "Install" : "Install and replace") { model.install() }
                    .buttonStyle(InstallerPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(InstallerColors.secondary).frame(width: 76, alignment: .leading)
            Text(value).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func installing(_ stage: AppInstaller.Stage) -> some View {
        let (label, fraction): (String, Double) = switch stage {
        case .copying: ("Copying Ensemble to \(model.destinationName)", 0.35)
        case .checking: ("Checking the copy", 0.75)
        case .finishing: ("Finishing", 1)
        }
        return VStack(alignment: .leading, spacing: 22) {
            heading("Installing", label)
            progressBar(fraction, label: "Install progress")
            Spacer()
        }
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Set up the engine", "Ensemble is installed. It runs its agents through OpenCode, a free, open-source program that is not on this Mac yet.")
            VStack(alignment: .leading, spacing: 12) {
                switch model.engineInstall {
                case .idle, .failed:
                    Text("The installer downloads OpenCode (about 110 MB) from OpenCode's own releases, checks that it is the file OpenCode published and signed, and puts it in \(model.engineFolderName).")
                        .font(.system(size: 12.5))
                        .foregroundStyle(InstallerColors.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = model.engineInstall {
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(InstallerColors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                case .working(let stage):
                    Text(Self.label(for: stage)).font(.system(size: 13, weight: .medium))
                    progressBar(Self.fraction(for: stage), label: "Engine install progress")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(InstallerColors.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(InstallerColors.border, lineWidth: 1))
            if model.setup.homebrewInstalled, !model.isInstallingEngine {
                HStack(spacing: 8) {
                    Text("Or with Homebrew:").font(.system(size: 12)).foregroundStyle(InstallerColors.secondary)
                    Text(EngineSetup.openCodeCommand).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    Button(model.copied ? "Copied" : "Copy") { model.copyHomebrewCommand() }
                        .buttonStyle(InstallerSecondaryButton())
                        .accessibilityLabel("Copy the Homebrew command")
                }
            }
            Spacer(minLength: 0)
            if !model.isInstallingEngine {
                HStack(spacing: 10) {
                    if model.checkedWithoutLuck {
                        Text("OpenCode is not installed yet.").font(.system(size: 12)).foregroundStyle(InstallerColors.secondary)
                    }
                    Spacer()
                    Button("Set up later") { model.setUpLater() }.buttonStyle(InstallerSecondaryButton())
                    Button(model.engineInstall == .idle ? "Install the engine" : "Try again") { model.installEngine() }
                        .buttonStyle(InstallerPrimaryButton())
                        .keyboardShortcut(.defaultAction)
                }
            }
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

    private func progressBar(_ fraction: Double, label: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(InstallerColors.code)
                Capsule().fill(InstallerColors.accent).frame(width: max(8, proxy.size.width * fraction))
            }
        }
        .frame(height: 8)
        .animation(.easeInOut(duration: 0.35), value: fraction)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(InstallerColors.success)
                .accessibilityHidden(true)
            heading("Ensemble is installed", model.setup.openCodeInstalled
                    ? "It is in \(model.destinationName), and its engine is ready. You can eject the installer disk and delete the download."
                    : "It is in \(model.destinationName). The engine is not set up yet: Ensemble offers to install it when you open it. You can eject the installer disk and delete the download.")
            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button("Show in Finder") { model.showInFinder() }.buttonStyle(InstallerSecondaryButton())
                Button("Open Ensemble") { model.openEnsemble() }
                    .buttonStyle(InstallerPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(InstallerColors.danger)
                .accessibilityHidden(true)
            heading("Ensemble was not installed", message)
            Spacer()
            HStack {
                Spacer()
                Button("Try again") { model.install() }
                    .buttonStyle(InstallerPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct InstallerPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(InstallerColors.accent).opacity(configuration.isPressed ? 0.8 : 1))
            .contentShape(Rectangle())
    }
}

struct InstallerSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(InstallerColors.text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(InstallerColors.raised).opacity(configuration.isPressed ? 0.7 : 1))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(InstallerColors.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}
