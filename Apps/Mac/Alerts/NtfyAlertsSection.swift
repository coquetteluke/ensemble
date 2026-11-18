import SwiftUI
import EnsembleKit

/// "Send alerts through ntfy" for the Alerts settings form: the user's own server, topic and optional token (kept in the
/// keychain), Hide session titles, Save and Send a test alert.
struct NtfyAlertsSection: View {
    @Bindable var center: NtfyAlertCenter
    @Environment(\.theme) private var theme
    @State private var server: String
    @State private var topic: String
    @State private var token: String
    @State private var problem: String?
    @State private var savedNote = false

    /// `draft` and `problem` start the fields with unsaved text and a refusal on screen (snapshots).
    init(center: NtfyAlertCenter = .shared, draft: NtfyAlerts.Settings? = nil, problem: String? = nil) {
        self.center = center
        let shown = draft ?? center.settings
        _server = State(initialValue: shown?.server ?? "")
        _topic = State(initialValue: shown?.topic ?? "")
        _token = State(initialValue: shown?.accessToken ?? "")
        _problem = State(initialValue: problem)
    }

    private var edited: Bool {
        let saved = center.settings
        return server.trimmingCharacters(in: .whitespacesAndNewlines) != (saved?.server ?? "")
            || topic.trimmingCharacters(in: .whitespacesAndNewlines) != (saved?.topic ?? "")
            || token.trimmingCharacters(in: .whitespacesAndNewlines) != (saved?.accessToken ?? "")
    }

    var body: some View {
        Section {
            Toggle("Send alerts through ntfy", isOn: $center.enabled)
            if center.enabled {
                TextField("Server", text: $server, prompt: Text(verbatim: "https://ntfy.sh"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                LabeledContent {
                    HStack(spacing: theme.z(8)) {
                        TextField("Topic", text: $topic, prompt: Text("Letters, numbers, - and _"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                        Button("Random topic") { topic = NtfyAlertCenter.randomTopic() }
                            .help("Fills in a random topic nobody can guess")
                    }
                } label: {
                    Text("Topic")
                }
                SecureField("Access token", text: $token, prompt: Text("Optional"))
                Toggle(isOn: $center.hideTitles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide session titles")
                        Text("Sends \"A session needs you\" instead of \"Needs you: Fix login redirect\".")
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                LabeledContent {
                    HStack(spacing: theme.z(8)) {
                        Button("Save") { save() }
                            .disabled(!edited)
                        Button(center.sendingTest ? "Sending" : "Send a test alert") { sendTest() }
                            .disabled(center.sendingTest || (center.settings == nil && server.isEmpty))
                    }
                } label: {
                    statusLine
                }
            }
        } header: {
            Text("Phone alerts")
        } footer: {
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Text("When a session needs you, finishes or fails, Ensemble posts one short line such as \"Needs you: Fix login redirect\" to your ntfy topic, and the ntfy app on your iPhone shows it. Subscribe to the same server and topic there. Alerts never include messages, commands or file paths. The server, topic and token stay in this Mac's keychain.")
                Text("Plain http is refused except for this Mac (localhost) and Tailscale names (*.ts.net): over any other network it would send the alert and your token unencrypted. Anyone who knows a topic on a public server can read it, so use one nobody can guess.")
            }
            .font(theme.font(size: 11.5))
            .foregroundStyle(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.danger)
        } else if savedNote, center.status == nil {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.success)
        } else {
            switch center.status {
            case .sent(let test, let date)?:
                Label(test ? "Test alert sent \(date.formatted(date: .omitted, time: .shortened))"
                           : "Last alert sent \(date.formatted(date: .omitted, time: .shortened))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
            case .failed(let reason)?:
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.danger)
            case nil:
                Text(center.settings == nil ? "Not set up yet" : "Ready")
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    /// Saves what is typed; false (with the reason on screen) when the server or topic cannot be used.
    @discardableResult
    private func save() -> Bool {
        do {
            try center.save(server: server, topic: topic, accessToken: token)
            problem = nil
            savedNote = true
            if let saved = center.settings {
                server = saved.server
                topic = saved.topic
            }
            return true
        } catch {
            problem = error.localizedDescription
            savedNote = false
            return false
        }
    }

    private func sendTest() {
        if edited || center.settings == nil {
            guard save() else { return }
        }
        Task { await center.sendTest() }
    }
}
