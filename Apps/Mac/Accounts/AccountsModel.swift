import AppKit
import EnsembleKit
import Observation

/// A short status line under an account row.
struct AccountNote: Equatable {
    var text: String
    var isError: Bool
}

/// A browser sign-in in progress.
struct SignInFlow: Equatable {
    enum Phase: Equatable {
        case waiting
        case finishing
        case failed(String)
        case expired
    }

    var attempt: OAuthAttempt
    var phase: Phase
}

/// Whether Google's Antigravity command line tool (`agy`) is installed. A placeholder until the ACP engine lands.
struct AntigravityInstall: Equatable, Sendable {
    var path: String?
    var version: String?
    var installed: Bool { path != nil }

    /// Looks for `agy` in Homebrew's folders, `~/.local/bin` and PATH, and asks it for its version.
    static func detect() async -> AntigravityInstall {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] + pathEntries
            guard let path = candidates.lazy.map({ "\($0)/agy" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return AntigravityInstall()
            }
            return AntigravityInstall(path: path, version: Self.version(of: path))
        }.value
    }

    private static func version(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(40))
    }
}

/// Sign-ins and keys for every engine: the Claude engine's own sign-in state, Antigravity, and OpenCode's
/// integrations (browser sign-ins, cloud accounts, coding plans, API keys).
///
/// Keys typed here go straight to the engine and are cleared from the field; nothing here reads, keeps or logs a
/// stored secret.
@MainActor
@Observable
final class AccountsModel {
    let store: SessionStore?
    let openCode: OpenCodeClient?
    let claude: ClaudeCodeEngine?

    private(set) var integrations: [OpenCodeIntegration] = []
    private(set) var claudeState: ClaudeAuthState?
    private(set) var claudeLimits: ClaudePlanLimits?
    private(set) var antigravity: AntigravityInstall?
    private(set) var loading = false
    private(set) var loadError: String?
    private(set) var flows: [String: SignInFlow] = [:]
    private(set) var notes: [String: AccountNote] = [:]
    private(set) var busy: Set<String> = []

    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]

    init(store: SessionStore) {
        self.store = store
        if let router = store.engine as? EngineRouter {
            openCode = router.engine(OpenCodeClient.self)
            claude = router.engine(ClaudeCodeEngine.self)
        } else {
            openCode = store.engine as? OpenCodeClient
            claude = store.engine as? ClaudeCodeEngine
        }
    }

    /// Fixed data for snapshots and previews.
    init(integrations: [OpenCodeIntegration], claudeState: ClaudeAuthState?, claudeLimits: ClaudePlanLimits?,
         antigravity: AntigravityInstall?) {
        store = nil
        openCode = nil
        claude = nil
        self.integrations = integrations
        self.claudeState = claudeState
        self.claudeLimits = claudeLimits
        self.antigravity = antigravity
    }

    var hasEngine: Bool { openCode != nil || claude != nil }
    var hasClaudeEngine: Bool { claude != nil || claudeState != nil }

    // MARK: Lists

    /// Providers with a browser sign-in, the big subscriptions first.
    var browserSignIns: [OpenCodeIntegration] {
        let order = ["openai", "xai", "github-copilot", "gitlab", "poe", "opencode"]
        return integrations.filter { !$0.oauthMethods.isEmpty }.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// AWS Bedrock, Google Vertex, the Claude Agent login.
    var cloudAccounts: [OpenCodeIntegration] {
        integrations.filter { !$0.externalMethods.isEmpty }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var codingPlans: [OpenCodeIntegration] {
        integrations.filter { $0.isCodingPlan && $0.keyMethod != nil }.sorted(by: Self.connectedThenName)
    }

    /// Every provider that takes an API key (coding plans are listed under subscriptions instead).
    func keyProviders(matching search: String) -> [OpenCodeIntegration] {
        let featured = ["anthropic", "openai", "xai", "google", "openrouter"]
        let query = search.trimmingCharacters(in: .whitespaces)
        return integrations.filter { integration in
            guard integration.keyMethod != nil, !integration.isCodingPlan else { return false }
            guard !query.isEmpty else { return true }
            return integration.name.localizedCaseInsensitiveContains(query) || integration.id.localizedCaseInsensitiveContains(query)
        }.sorted { a, b in
            if a.hasKey != b.hasKey { return a.hasKey }
            let fa = featured.firstIndex(of: a.id) ?? Int.max
            let fb = featured.firstIndex(of: b.id) ?? Int.max
            if fa != fb { return fa < fb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var connectedKeyCount: Int { integrations.filter { $0.keyMethod != nil && !$0.isCodingPlan && $0.hasKey }.count }

    private static func connectedThenName(_ a: OpenCodeIntegration, _ b: OpenCodeIntegration) -> Bool {
        if a.hasKey != b.hasKey { return a.hasKey }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: Loading

    func load(refresh: Bool = false) async {
        guard hasEngine, !loading else { return }
        loading = true
        defer { loading = false }
        async let claudeState = claude?.authState(refresh: refresh)
        async let claudeLimits = claude?.planLimits()
        async let antigravity = AntigravityInstall.detect()
        if let openCode {
            do {
                integrations = try await openCode.integrations()
                loadError = nil
            } catch {
                loadError = "Could not load providers from OpenCode: \(error.localizedDescription)"
            }
        }
        self.claudeState = await claudeState
        self.claudeLimits = await claudeLimits
        self.antigravity = await antigravity
        if refresh { await store?.refreshProviders() }
    }

    private func reload(_ integrationID: String) async {
        guard let openCode else { return }
        if let fresh = try? await openCode.integration(integrationID), let index = integrations.firstIndex(where: { $0.id == integrationID }) {
            integrations[index] = fresh
        }
        await store?.refreshProviders()
    }

    private func run(_ id: String, success: String?, failure: String, _ body: () async throws -> Void) async {
        busy.insert(id)
        notes[id] = nil
        defer { busy.remove(id) }
        do {
            try await body()
            if let success { notes[id] = AccountNote(text: success, isError: false) }
            await reload(id)
        } catch {
            notes[id] = AccountNote(text: "\(failure): \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Keys

    func saveKey(_ integration: OpenCodeIntegration, key: String, values: [String: String]) async -> Bool {
        guard let openCode else { return false }
        let fields = integration.keyMethod?.fields ?? []
        if let missing = OpenCodeIntegration.FormField.missing(in: fields, values: values).first {
            notes[integration.id] = AccountNote(text: "Fill in \(missing.title ?? missing.key).", isError: true)
            return false
        }
        let answer = OpenCodeIntegration.FormField.answer(for: fields, values: values)
        var saved = false
        await run(integration.id, success: "Saved", failure: "Could not save the key") {
            try await openCode.connectKey(integrationID: integration.id, key: key, answer: answer)
            saved = true
        }
        return saved
    }

    /// Removes stored keys only; a browser sign-in for the same provider stays.
    func removeKey(_ integration: OpenCodeIntegration) async {
        guard let openCode else { return }
        await run(integration.id, success: "Removed", failure: "Could not remove the key") {
            try await openCode.removeCredentials(integrationID: integration.id, method: .key)
        }
    }

    // MARK: Cloud accounts

    func connectExternal(_ integration: OpenCodeIntegration, method: OpenCodeIntegration.Method, values: [String: String]) async {
        guard let openCode, let methodID = method.methodID else { return }
        if let missing = OpenCodeIntegration.FormField.missing(in: method.fields, values: values).first {
            notes[integration.id] = AccountNote(text: "Fill in \(missing.title ?? missing.key).", isError: true)
            return
        }
        let answer = OpenCodeIntegration.FormField.answer(for: method.fields, values: values)
        await run(integration.id, success: "Connected", failure: "Could not connect") {
            try await openCode.connectExternal(integrationID: integration.id, methodID: methodID, answer: answer)
        }
    }

    func disconnectExternal(_ integration: OpenCodeIntegration) async {
        guard let openCode else { return }
        await run(integration.id, success: "Disconnected", failure: "Could not disconnect") {
            try await openCode.removeCredentials(integrationID: integration.id, method: .external)
        }
    }

    // MARK: Browser sign-in

    func startSignIn(_ integration: OpenCodeIntegration, method: OpenCodeIntegration.Method, values: [String: String]) async {
        guard let openCode, let methodID = method.methodID else { return }
        if let missing = OpenCodeIntegration.FormField.missing(in: method.fields, values: values).first {
            notes[integration.id] = AccountNote(text: "Fill in \(missing.title ?? missing.key).", isError: true)
            return
        }
        await cancelSignIn(integration.id)
        busy.insert(integration.id)
        notes[integration.id] = nil
        defer { busy.remove(integration.id) }
        do {
            let attempt = try await openCode.startOAuth(integrationID: integration.id, methodID: methodID,
                                                        answer: OpenCodeIntegration.FormField.answer(for: method.fields, values: values))
            flows[integration.id] = SignInFlow(attempt: attempt, phase: .waiting)
            openBrowser(attempt)
            if attempt.mode == .auto { poll(attempt) }
        } catch {
            notes[integration.id] = AccountNote(text: "Could not start the sign-in: \(error.localizedDescription)", isError: true)
        }
    }

    func openBrowser(_ attempt: OAuthAttempt) {
        guard let url = attempt.url, url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Sends the code (or, for sign-ins that finish by themselves, the redirect address) from the browser.
    func finishSignIn(_ integrationID: String, code: String) async {
        guard let openCode, var flow = flows[integrationID] else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        flow.phase = .finishing
        flows[integrationID] = flow
        do {
            try await openCode.completeOAuth(integrationID: integrationID, attemptID: flow.attempt.attemptID, code: trimmed)
            if flow.attempt.mode == .code {
                await signInCompleted(integrationID)
            } else {
                flows[integrationID]?.phase = .waiting
                poll(flow.attempt)
            }
        } catch {
            flows[integrationID]?.phase = .failed("The code was not accepted: \(error.localizedDescription)")
        }
    }

    func cancelSignIn(_ integrationID: String) async {
        pollTasks.removeValue(forKey: integrationID)?.cancel()
        guard let flow = flows.removeValue(forKey: integrationID) else { return }
        if case .waiting = flow.phase {
            try? await openCode?.cancelOAuth(integrationID: integrationID, attemptID: flow.attempt.attemptID)
        }
    }

    /// Removes the browser sign-in only; a stored key for the same provider stays.
    func signOut(_ integration: OpenCodeIntegration) async {
        guard let openCode else { return }
        await run(integration.id, success: "Signed out", failure: "Could not sign out") {
            try await openCode.removeCredentials(integrationID: integration.id, method: .oauth)
        }
    }

    private func poll(_ attempt: OAuthAttempt) {
        let integrationID = attempt.integrationID
        pollTasks[integrationID]?.cancel()
        pollTasks[integrationID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let openCode = self.openCode,
                      self.flows[integrationID]?.attempt.attemptID == attempt.attemptID else { return }
                if let expires = attempt.expires, Date() > expires.addingTimeInterval(5) {
                    self.flows[integrationID]?.phase = .expired
                    return
                }
                do {
                    switch try await openCode.oauthStatus(integrationID: integrationID, attemptID: attempt.attemptID) {
                    case .pending:
                        continue
                    case .complete:
                        await self.signInCompleted(integrationID)
                        return
                    case .failed(let message):
                        self.flows[integrationID]?.phase = .failed(message)
                        return
                    case .expired:
                        self.flows[integrationID]?.phase = .expired
                        return
                    }
                } catch let error as OpenCodeError where error.status == 404 {
                    self.flows[integrationID]?.phase = .failed("The engine no longer has this sign-in. Start again.")
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func signInCompleted(_ integrationID: String) async {
        pollTasks.removeValue(forKey: integrationID)?.cancel()
        flows[integrationID] = nil
        notes[integrationID] = AccountNote(text: "Signed in", isError: false)
        await reload(integrationID)
    }

    func stopAll() {
        for task in pollTasks.values { task.cancel() }
        pollTasks.removeAll()
    }
}
