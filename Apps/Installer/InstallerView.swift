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
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(InstallerColors.raised)
                    Capsule().fill(InstallerColors.accent).frame(width: max(8, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            .animation(.easeInOut(duration: 0.35), value: fraction)
            .accessibilityLabel("Install progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            Spacer()
        }
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Set up the engine", "Ensemble is installed. It runs its agents through OpenCode, which is not on this Mac yet. "
                    + (model.steps.count == 1 ? "Run this command in Terminal." : "Run these commands in Terminal, one at a time.")
                    + " This window moves on by itself when OpenCode is installed.")
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                commandCard(step, number: model.steps.count > 1 ? index + 1 : nil)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Open Terminal") { model.openTerminal() }.buttonStyle(InstallerSecondaryButton())
                if model.checkedWithoutLuck {
                    Text("OpenCode is not installed yet.").font(.system(size: 12)).foregroundStyle(InstallerColors.secondary)
                }
                Spacer()
                Button("Set up later") { model.setUpLater() }.buttonStyle(InstallerSecondaryButton())
                Button("Check again") { model.checkAgain() }
                    .buttonStyle(InstallerPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func commandCard(_ step: EngineSetup.Step, number: Int?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(number.map { "\($0). \(step.title)" } ?? step.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if step.done {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(InstallerColors.success)
                }
            }
            HStack(spacing: 10) {
                Text(step.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(model.copied == step.kind ? "Copied" : "Copy") { model.copy(step) }
                    .buttonStyle(InstallerSecondaryButton())
                    .accessibilityLabel("Copy the command for \(step.title)")
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(InstallerColors.code))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(InstallerColors.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(InstallerColors.border, lineWidth: 1))
        .opacity(step.done ? 0.6 : 1)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(InstallerColors.success)
                .accessibilityHidden(true)
            heading("Ensemble is installed", model.setup.openCodeInstalled
                    ? "It is in \(model.destinationName), and its engine is ready. You can eject the installer disk and delete the download."
                    : "It is in \(model.destinationName). The engine is not set up yet: Ensemble shows the same commands when you open it. You can eject the installer disk and delete the download.")
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
