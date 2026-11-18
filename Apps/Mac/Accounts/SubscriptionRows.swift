import SwiftUI
import EnsembleKit

/// Names people know their subscription by.
enum AccountNames {
    static func subscriptionTitle(_ integration: OpenCodeIntegration) -> String {
        switch integration.id {
        case "openai": "ChatGPT"
        case "xai": "SuperGrok"
        case "gitlab": "GitLab Duo"
        default: integration.name
        }
    }

    static func subscriptionSubtitle(_ integration: OpenCodeIntegration) -> String? {
        let title = subscriptionTitle(integration)
        return title == integration.name ? nil : integration.name
    }

    static func planLabel(_ subscriptionType: String?) -> String? {
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespaces), !type.isEmpty else { return nil }
        return type.prefix(1).uppercased() + type.dropFirst() + " plan"
    }
}

// MARK: Claude

/// The Claude engine runs the official `claude` command signed in as the user; Ensemble only reads whether it is
/// installed and signed in, and never touches the login.
struct ClaudeAccountRow: View {
    @Environment(\.theme) private var theme
    let model: AccountsModel

    var body: some View {
        AccountCard {
            AccountHeader(title: "Claude", subtitle: subtitle, status: status)
            if let state = model.claudeState {
                if !state.installed {
                    SetupStepsView(steps: [
                        .text("Install the claude command line tool in Terminal:"),
                        .command("curl -fsSL https://claude.ai/install.sh | bash"),
                        .text("Then run claude in Terminal, sign in with your Claude account, and press Check again."),
                    ])
                } else if !state.loggedIn {
                    SetupStepsView(steps: [
                        .text("Run this in Terminal and sign in with your Claude account, then press Check again:"),
                        .command("claude"),
                    ])
                } else if state.authMethod != nil, state.authMethod != "claude.ai" {
                    Text("This sign-in is not a Claude plan, so subscription agents are billed through it.")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    PlanLimitsView(limits: model.claudeLimits)
                }
            } else if !model.hasClaudeEngine {
                Text("The Claude engine is not set up in this window.")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var subtitle: String? {
        guard let state = model.claudeState, state.installed else { return nil }
        return state.version.map { "claude \($0)" }
    }

    private var status: AccountStatus {
        guard let state = model.claudeState else { return model.loading ? .working("Checking") : .off("Unknown") }
        if !state.installed { return .off("Not installed") }
        if !state.loggedIn { return .warning("Not signed in") }
        if state.authMethod == "claude.ai" || state.authMethod == nil {
            return .good(["Signed in", AccountNames.planLabel(state.subscriptionType)].compactMap { $0 }.joined(separator: ", "))
        }
        return .good("Signed in (\(state.authMethod ?? ""))")
    }
}

// MARK: Google AI (Antigravity)

/// Placeholder until the ACP engine runs Gemini agents through Google's own `agy`.
struct AntigravityAccountRow: View {
    @Environment(\.theme) private var theme
    let install: AntigravityInstall?
    let loading: Bool

    var body: some View {
        AccountCard {
            AccountHeader(title: "Google AI", subtitle: subtitle, status: status)
            if let install, !install.installed {
                SetupStepsView(steps: [
                    .text("Install Google's Antigravity command line tool:"),
                    .command("brew install --cask antigravity-cli"),
                    .text("Then run agy once in Terminal to sign in with your Google account."),
                ])
            } else if install != nil {
                SetupStepsView(steps: [
                    .text("agy uses the Antigravity app's sign-in. If it is not signed in, run agy once in Terminal."),
                    .text("Gemini agents are not available in this version yet."),
                ])
            }
        }
    }

    private var subtitle: String? {
        guard let install, install.installed else { return "Antigravity" }
        return ["Antigravity", install.version.map { "agy \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private var status: AccountStatus {
        guard let install else { return loading ? .working("Checking") : .off("Unknown") }
        return install.installed ? .good("Installed") : .off("Not installed")
    }
}

// MARK: Browser sign-in

/// A provider with an OAuth method (ChatGPT, SuperGrok, GitHub Copilot, GitLab Duo, Poe, OpenCode Console...).
struct BrowserSignInRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    let model: AccountsModel
    let integration: OpenCodeIntegration
    @State private var values: [String: String] = [:]
    @State private var chosenMethodID: String?
    @State private var code = ""

    private var methods: [OpenCodeIntegration.Method] { integration.oauthMethods }
    private var primary: OpenCodeIntegration.Method? { methods.first { !$0.isLegacy } ?? methods.first }
    private var chosen: OpenCodeIntegration.Method? {
        chosenMethodID.flatMap { id in methods.first { $0.methodID == id } }
    }
    private var flow: SignInFlow? { model.flows[integration.id] }
    private var busy: Bool { model.busy.contains(integration.id) }

    var body: some View {
        AccountCard {
            AccountHeader(title: AccountNames.subscriptionTitle(integration), subtitle: AccountNames.subscriptionSubtitle(integration),
                          status: status) {
                actions
            }
            if let flow {
                SignInFlowView(model: model, integrationID: integration.id, flow: flow, code: $code)
            } else if let method = chosen {
                AccountFormFields(fields: method.fields, values: $values)
                HStack(spacing: theme.z(8)) {
                    Button("Continue in browser") { start(method) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(busy)
                    Button("Cancel") { chosenMethodID = nil }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if let needsAuth = integration.connections(method: .oauth).first(where: \.needsAuth) {
                Text(needsAuth.statusMessage ?? "The sign-in has expired. Sign in again.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.warning)
            }
            AccountNoteText(note: model.notes[integration.id])
        }
    }

    @ViewBuilder private var actions: some View {
        if flow == nil {
            if integration.isSignedIn {
                Button("Sign out") { Task { await model.signOut(integration) } }
                    .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                    .disabled(busy)
            }
            if !integration.isSignedIn || integration.needsAuth, let primary {
                Button(integration.needsAuth ? "Sign in again" : "Sign in") { choose(primary) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
            }
            let others = methods.filter { $0.methodID != primary?.methodID }
            if !others.isEmpty, !integration.isSignedIn, isSnapshot {
                Image(systemName: "ellipsis").foregroundStyle(theme.textSecondary)
            } else if !others.isEmpty, !integration.isSignedIn {
                Menu {
                    ForEach(others) { method in
                        Button(method.label ?? method.methodID ?? "Sign in") { choose(method) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Other ways to sign in")
            }
        }
    }

    private var status: AccountStatus {
        if flow != nil { return .working("Signing in") }
        if integration.needsAuth { return .warning("Sign in again") }
        return integration.isSignedIn ? .good("Signed in") : .off("Not signed in")
    }

    /// Methods with visible fields show their form first; others go straight to the browser.
    private func choose(_ method: OpenCodeIntegration.Method) {
        values = [:]
        if method.fields.contains(where: { $0.kind != .external && $0.isVisible(in: [:], fields: method.fields) }) {
            chosenMethodID = method.methodID
        } else {
            start(method)
        }
    }

    private func start(_ method: OpenCodeIntegration.Method) {
        code = ""
        Task {
            await model.startSignIn(integration, method: method, values: values)
            if model.flows[integration.id] != nil { chosenMethodID = nil }
        }
    }
}

/// Instructions while the browser step runs, with a code field when the provider shows a code to paste back.
struct SignInFlowView: View {
    @Environment(\.theme) private var theme
    let model: AccountsModel
    let integrationID: String
    let flow: SignInFlow
    @Binding var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            if !flow.attempt.instructions.isEmpty {
                Text(flow.attempt.instructions)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectableText()
            }
            switch flow.phase {
            case .waiting, .finishing:
                if flow.attempt.mode == .code || flow.attempt.acceptsPaste {
                    HStack(spacing: theme.z(8)) {
                        InputField(flow.attempt.mode == .code ? "Code from the browser" : "Address from the browser, if it does not finish by itself",
                                   text: $code, monospaced: true)
                            .onSubmit(finish)
                        Button("Finish sign-in", action: finish)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || flow.phase == .finishing)
                    }
                }
                HStack(spacing: theme.z(8)) {
                    if flow.attempt.mode == .auto {
                        Spinner(size: theme.z(11))
                        Text("Waiting for the browser")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Button("Open the page again") { model.openBrowser(flow.attempt) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Cancel") { Task { await model.cancelSignIn(integrationID) } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            case .failed(let message):
                failure(message)
            case .expired:
                failure("The sign-in timed out.")
            }
        }
    }

    private func failure(_ message: String) -> some View {
        HStack(spacing: theme.z(8)) {
            Text(message)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Close") { Task { await model.cancelSignIn(integrationID) } }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func finish() {
        let text = code
        Task {
            await model.finishSignIn(integrationID, code: text)
            code = ""
        }
    }
}

// MARK: Cloud accounts

/// AWS Bedrock, Google Vertex and the Claude Agent login: credentials made outside Ensemble, linked by reference.
struct CloudAccountRow: View {
    @Environment(\.theme) private var theme
    let model: AccountsModel
    let integration: OpenCodeIntegration
    @State private var values: [String: String] = [:]
    @State private var expanded = false

    private var method: OpenCodeIntegration.Method? { integration.externalMethods.first }
    private var busy: Bool { model.busy.contains(integration.id) }

    var body: some View {
        AccountCard {
            AccountHeader(title: integration.name, subtitle: method.map(Self.subtitle(for:)), status: status) {
                if integration.isExternallyConnected {
                    Button("Disconnect") { Task { await model.disconnectExternal(integration) } }
                        .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                        .disabled(busy)
                } else {
                    Button(expanded ? "Hide steps" : "Set up") { expanded.toggle() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if expanded, !integration.isExternallyConnected, let method {
                SetupStepsView(steps: Self.steps(for: method))
                AccountFormFields(fields: method.fields, values: $values)
                Button("Connect") { Task { await model.connectExternal(integration, method: method, values: values) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
            }
            AccountNoteText(note: model.notes[integration.id])
        }
    }

    private var status: AccountStatus {
        if integration.needsAuth { return .warning("Sign in again") }
        return integration.isExternallyConnected ? .good("Connected") : .off("Not connected")
    }

    static func subtitle(for method: OpenCodeIntegration.Method) -> String {
        switch method.methodID {
        case "aws-profile": "AWS profile (SSO or named profile)"
        case "google-adc": "Google Cloud credentials (gcloud)"
        case "claude-login": "The claude command's own sign-in"
        default: (method.label ?? "Existing credentials").replacingOccurrences(of: "Claude Code", with: "claude command")
        }
    }

    static func steps(for method: OpenCodeIntegration.Method) -> [SetupStep] {
        switch method.methodID {
        case "aws-profile":
            [.text("Sign in to AWS in Terminal (use your profile's name):"),
             .command("aws sso login --profile my-profile"),
             .text("Enter the profile name below and press Connect.")]
        case "google-adc":
            [.text("Sign in to Google Cloud in Terminal:"),
             .command("gcloud auth application-default login"),
             .text("Enter the project and location below and press Connect.")]
        case "claude-login":
            [.text("Sign in with the claude command in Terminal:"),
             .command("claude auth login"),
             .text("Press Connect to let OpenCode agents use that sign-in. The Claude row above is Ensemble's own Claude engine.")]
        default:
            [.text(subtitle(for: method))]
        }
    }
}

// MARK: Keys

/// A provider that takes a key: coding plans under subscriptions, and every provider in the API keys list.
struct KeyAccountRow: View {
    @Environment(\.theme) private var theme
    let model: AccountsModel
    let integration: OpenCodeIntegration
    /// Collapsed rows show the key field only after Add key is pressed (the API keys list has 330 of them).
    var collapsible = false
    /// Tighter card for long lists.
    var compact = false
    @State private var key = ""
    @State private var values: [String: String] = [:]
    @State private var open = false

    private var busy: Bool { model.busy.contains(integration.id) }
    private var storedKeys: [OpenCodeIntegration.Connection] { integration.connections(method: .key) }

    var body: some View {
        AccountCard(compact: compact) {
            AccountHeader(title: integration.name, subtitle: integration.id, status: status) {
                if collapsible && !open {
                    Button(storedKeys.isEmpty ? "Add key" : "Replace key") { open = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !storedKeys.isEmpty {
                    Button("Remove") { Task { await model.removeKey(integration) } }
                        .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                        .disabled(busy)
                }
            }
            if !collapsible || open {
                AccountFormFields(fields: integration.keyMethod?.fields ?? [], values: $values)
                HStack(spacing: theme.z(8)) {
                    InputField(storedKeys.isEmpty ? (integration.keyMethod?.label ?? "Key") : "Replace key", text: $key,
                               secure: true, monospaced: true)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    if collapsible {
                        Button("Cancel") {
                            key = ""
                            open = false
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            if let env = integration.environmentConnections.first?.environmentName {
                Text("Using \(env) from the environment.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            if let needsAuth = storedKeys.first(where: \.needsAuth) {
                Text(needsAuth.statusMessage ?? "The key was rejected. Replace it.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.warning)
            }
            AccountNoteText(note: model.notes[integration.id])
        }
    }

    private var status: AccountStatus {
        if storedKeys.contains(where: \.needsAuth) { return .warning("Key rejected") }
        return integration.hasKey ? .good("Connected") : .off("No key")
    }

    private func save() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        key = ""
        Task {
            if await model.saveKey(integration, key: typed, values: values) { open = false }
        }
    }
}
