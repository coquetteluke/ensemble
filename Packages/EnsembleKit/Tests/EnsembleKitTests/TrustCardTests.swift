import Foundation
import Testing
@testable import EnsembleKit

/// A temporary home folder with a project in it, and a trust list of its own (never the app's).
struct TrustBox {
    let root: URL
    let home: URL
    let project: URL
    let trust: WorkspaceTrust

    init() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: WorkspaceTrust.resolvedPath(fm.temporaryDirectory.path) ?? fm.temporaryDirectory.path)
        root = base.appendingPathComponent("ens-trust-\(UUID().uuidString.prefix(8))", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        project = home.appendingPathComponent("code/widgets", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        trust = WorkspaceTrust(fileURL: root.appendingPathComponent("trusted-folders.json"), homeDirectory: home.path)
    }

    func write(_ relative: String, in folder: URL? = nil, _ text: String = "{}") throws {
        let url = (folder ?? project).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func folder(_ relative: String, in base: URL? = nil) throws {
        try FileManager.default.createDirectory(at: (base ?? project).appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Workspace trust card", .serialized)
struct TrustCardTests {
    // MARK: Project files

    @Test func scanListsEachEnginesFilesUpToTheHomeFolder() throws {
        let box = try TrustBox()
        defer { box.remove() }
        try box.write(".claude/settings.json")
        try box.write(".mcp.json")
        try box.folder(".claude/skills")
        try box.write("OpenCode.JSON")
        try box.folder(".opencode/plugins")
        try box.write("AGENTS.md", "Be brief.")
        try box.write("GEMINI.md", "Be brief.")
        try box.folder(".agents")
        try box.write("opencode.jsonc", in: box.home.appendingPathComponent("code"))
        // The home folder's own files are the user's config, not the project's.
        try box.write("opencode.json", in: box.home)
        try box.write("AGENTS.md", in: box.home)

        let files = ProjectTrustFiles.scan(box.project.path, homeDirectory: box.home.path)
        #expect(files.claude == [".claude/settings.json", ".mcp.json", ".claude/skills"])
        #expect(files.openCode == ["OpenCode.JSON", ".opencode/", "AGENTS.md", "../opencode.jsonc"])
        #expect(files.gemini == [".agents/", "GEMINI.md", "AGENTS.md"])

        // The home folder (and anything above it) has no project files of its own.
        try box.write(".claude/settings.json", in: box.home)
        #expect(ProjectTrustFiles.scan(box.home.path, homeDirectory: box.home.path).isEmpty)
        #expect(ProjectTrustFiles.scan(box.root.path, homeDirectory: box.home.path).isEmpty)
        #expect(ProjectTrustFiles.scan(box.project.appendingPathComponent("missing").path, homeDirectory: box.home.path).isEmpty)
        #expect(ProjectTrustFiles.isInstructions("../AGENTS.md"))
        #expect(!ProjectTrustFiles.isInstructions("opencode.json"))
    }

    @Test func listsReadAsASentence() {
        #expect(ProjectTrustFiles.list(["a"]) == "a")
        #expect(ProjectTrustFiles.list(["a", "b"]) == "a and b")
        #expect(ProjectTrustFiles.list(["a", "b", "c"]) == "a, b and c")
        #expect(ProjectTrustFiles.list(["a", "b", "c", "d", "e"]) == "a, b and 3 more")
    }

    // MARK: Routing

    @Test func untrustedFoldersGoToTheUntrustedEngineAndTrustedOnesToTheFallback() async throws {
        let box = try TrustBox()
        defer { box.remove() }
        let shared = RouterCapableFakeEngine(name: "shared")
        let isolated = RouterCapableFakeEngine(name: "private")
        let claude = RouterFakeEngine(name: "claude")
        shared.state.withLock { $0.models = [ModelInfo(ref: ModelRef(providerID: "opencode", id: "big"), name: "Big", providerName: "OpenCode")] }
        isolated.state.withLock { $0.models = [ModelInfo(ref: ModelRef(providerID: "opencode", id: "copy"), name: "Copy", providerName: "OpenCode")] }
        let router = EngineRouter(fallback: shared, trust: box.trust)
        router.register(claude, providers: ["claude-code"], id: "claude", name: "Claude")
        router.registerForUntrustedFolders(isolated)
        let free = ModelRef(providerID: "opencode", id: "big")

        // Untrusted: OpenCode work goes to the untrusted-folder engine, Claude work stays with Claude.
        #expect(router.registration(forNewSessionIn: box.project.path, model: free).id == EngineRouter.untrustedOpenCodeID)
        let early = try await router.createSession(directory: box.project.path, model: free, agent: nil, permissionMode: .ask, parentID: nil)
        let unnamed = try await router.createSession(directory: box.project.path, model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        let claudeSession = try await router.createSession(directory: box.project.path, model: ModelRef(providerID: "claude-code", id: "opus"),
                                                           agent: nil, permissionMode: .ask, parentID: nil)
        #expect(router.ownerID(ofSession: early.id) == EngineRouter.untrustedOpenCodeID)
        #expect(router.ownerID(ofSession: unnamed.id) == EngineRouter.untrustedOpenCodeID)
        #expect(router.ownerID(ofSession: claudeSession.id) == "claude")
        #expect(!shared.calls.contains { $0.hasPrefix("create") })
        _ = try await router.createSchedule(title: "t", prompt: "p", directory: box.project.path, schedule: "0 9 * * *", model: free)
        #expect(isolated.calls.contains("createSchedule") && !shared.calls.contains("createSchedule"))

        // Folder lookups for an untrusted folder skip the fallback; app-wide lists skip the untrusted engine.
        let commands = try await router.commands(directory: box.project.path).map(\.name)
        #expect(commands.contains("private-only") && !commands.contains("shared-only"))
        let general = try await router.commands(directory: nil).map(\.name)
        #expect(general.contains("shared-only") && !general.contains("private-only"))
        #expect(try await router.models().map(\.id) == ["opencode/big"])

        // Trusted: new sessions go to the fallback; the earlier session stays where it is.
        try box.trust.trust(box.project.path)
        let later = try await router.createSession(directory: box.project.path, model: free, agent: nil, permissionMode: .ask, parentID: nil)
        #expect(router.ownerID(ofSession: later.id) == "opencode")
        #expect(router.ownerID(ofSession: early.id) == EngineRouter.untrustedOpenCodeID)
        try await router.prompt(early.id, text: "hi", files: [])
        #expect(isolated.calls.contains("prompt:\(early.id)"))
        let trustedCommands = try await router.commands(directory: box.project.path).map(\.name)
        #expect(trustedCommands.contains("shared-only") && !trustedCommands.contains("private-only"))

        // Both engines' sessions are listed.
        let listed = Set(try await router.listSessions().map(\.id))
        #expect(listed.isSuperset(of: [early.id, later.id]))
    }

    @Test func aStandInRefusesInsteadOfFallingBack() async throws {
        let box = try TrustBox()
        defer { box.remove() }
        let shared = RouterFakeEngine(name: "shared")
        let router = EngineRouter(fallback: shared, trust: box.trust)
        router.registerForUntrustedFolders(OpenCodeStandIn(reason: "starting"))
        await #expect(throws: PrivateOpenCodeError.notRunning("starting")) {
            _ = try await router.createSession(directory: box.project.path, model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        }
        #expect(shared.calls.isEmpty)
        // A trusted folder is unaffected.
        try box.trust.trust(box.project.path)
        _ = try await router.createSession(directory: box.project.path, model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        #expect(shared.calls.count == 1)
        // Listing still works while the stand-in is in place.
        #expect(try await router.listSessions().count == 1)
    }

    @Test func withoutAnUntrustedEngineRoutingIsUnchanged() async throws {
        let box = try TrustBox()
        defer { box.remove() }
        let shared = RouterFakeEngine(name: "shared")
        let router = EngineRouter(fallback: shared, trust: box.trust)
        let session = try await router.createSession(directory: box.project.path, model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        #expect(router.ownerID(ofSession: session.id) == "opencode")
    }

    // MARK: Card

    @MainActor
    @Test func cardFollowsTrustAndNotNow() async throws {
        let box = try TrustBox()
        defer { box.remove() }
        try box.write("opencode.json")
        try box.write("AGENTS.md", "Be brief.")
        let other = box.home.appendingPathComponent("code/gadgets", isDirectory: true)
        try box.write("opencode.json", in: other)
        let shared = RouterFakeEngine(name: "shared")
        let isolated = RouterFakeEngine(name: "private")
        let router = EngineRouter(fallback: shared, trust: box.trust)
        router.registerForUntrustedFolders(isolated)
        // An older session on the shared service in an untrusted folder.
        shared.setSessions([EngineSession(id: "old", title: "Old", directory: other.path)])
        let store = SessionStore(engine: router)
        let created = try await store.newSession(directory: box.project.path, model: nil, permissionMode: .ask)
        await store.reloadSessions()
        let session = try #require(store.session(created.id))
        let old = try #require(store.session("old"))

        let skipped = try #require(store.trustPrompt(for: session))
        #expect(skipped.kind == .skipped && skipped.engineName == "OpenCode")
        #expect(skipped.files == ["opencode.json", "AGENTS.md"])
        #expect(skipped.offersTrust)
        #expect(store.trustPrompt(for: old)?.kind == .loadsUntrusted)

        // Not now hides it for the folder only.
        store.dismissTrustPrompt(for: session)
        #expect(store.trustPrompt(for: session) == nil)
        #expect(store.trustPrompt(for: old) != nil)

        // Trusting (from anywhere: the same shared list) turns it into "keeps running without them".
        try box.trust.trust(box.project.path)
        store.trustNotes.dismissed.removeAll()
        let keeps = try #require(store.trustPrompt(for: session))
        #expect(keeps.kind == .keepsSkipping && !keeps.offersTrust)
        #expect(keeps.message.contains("New sessions here load them"))
        #expect(store.newSessionTrustLine(directory: box.project.path, model: nil)?.tone == .trusted)

        // The home folder cannot be trusted; the reason is kept for the card.
        let home = EngineSession(id: "home", title: "Home", directory: box.home.path)
        shared.setSessions([home])
        await store.reloadSessions()
        let homeSession = try #require(store.session("home"))
        #expect(!store.trustFolder(of: homeSession))
        #expect(store.trustError(for: box.home.path) == WorkspaceTrustError.tooBroad(box.home.path).errorDescription)
        // Old sessions on the shared service in trusted folders, and folders without config, get no card.
        #expect(store.trustPrompt(for: homeSession) == nil)
    }

    @MainActor
    @Test func newSessionLineNamesWhatTheAgentSkips() throws {
        let box = try TrustBox()
        defer { box.remove() }
        let shared = RouterFakeEngine(name: "shared")
        let router = EngineRouter(fallback: shared, trust: box.trust)
        router.registerForUntrustedFolders(RouterFakeEngine(name: "private"))
        let store = SessionStore(engine: router)
        #expect(store.newSessionTrustLine(directory: "", model: nil) == nil)
        let plain = store.newSessionTrustLine(directory: box.project.path, model: nil)
        #expect(plain == NewSessionTrustLine(text: "Not trusted. This folder has no agent settings of its own.", tone: .untrusted,
                                             offersTrust: false))
        try box.write("AGENTS.md", "Be brief.")
        store.trustNotes.scans.removeAll()
        #expect(store.newSessionTrustLine(directory: box.project.path, model: nil)?.offersTrust == false)
        try box.write("opencode.json")
        store.trustNotes.scans.removeAll()
        let line = try #require(store.newSessionTrustLine(directory: box.project.path, model: nil))
        #expect(line.text == "Not trusted. The agent skips opencode.json and AGENTS.md.")
        #expect(line.offersTrust)
        #expect(store.trustFolder(box.project.path))
        #expect(store.newSessionTrustLine(directory: box.project.path, model: nil)?.tone == .trusted)
    }

    #if os(macOS)
    /// An agent that refuses untrusted folders (the Gemini case, with the fake ACP agent): the card says so, the refused
    /// message is kept, and after trusting it is sent again with one call.
    @MainActor
    @Test func refusedMessageIsSentAgainAfterTrusting() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let box = try TrustBox()
        defer { box.remove() }
        try box.folder(".agents")
        try box.trust.trust(box.project.path)
        let script = Fixtures.url("acp/fake_acp_agent.py").path
        let env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                   "FAKE_ACP_LOG": box.root.appendingPathComponent("log.jsonl").path,
                   "FAKE_ACP_STATE": box.root.appendingPathComponent("state.json").path]
        let acp = ACPEngine(configuration: .init(agent: FakeACPHarness.definition(script: script), executablePath: "/usr/bin/python3",
                                                 storeURL: box.root.appendingPathComponent("acp.json"),
                                                 workDirectory: box.root.appendingPathComponent("work"),
                                                 baseEnvironment: env, trust: box.trust, requestTimeout: .seconds(20),
                                                 interruptGrace: .seconds(5)))
        defer { Task { await acp.shutdown() } }
        let router = EngineRouter(fallback: RouterFakeEngine(name: "shared"), trust: box.trust)
        router.register(acp, providers: ["fake"], id: "fake", name: "Fake Agent")
        let store = SessionStore(engine: router)
        let session = try await store.newSession(directory: box.project.path, model: ModelRef(providerID: "fake", id: "default"),
                                                 permissionMode: .ask)
        #expect(store.trustPrompt(for: session) == nil)

        try box.trust.revoke(box.project.path)
        let refused = try #require(store.trustPrompt(for: session))
        #expect(refused.kind == .refused && refused.engineName == "Fake Agent")
        #expect(refused.files == [".agents/"])
        #expect(store.newSessionTrustLine(directory: box.project.path, model: ModelRef(providerID: "fake", id: "default"))?.tone == .blocked)

        await store.send("hello", to: session.id)
        #expect(store.trustNotes.refusals[session.id]?.text == "hello")
        // Not now, then another refusal: the card comes back.
        store.dismissTrustPrompt(for: session)
        #expect(store.trustPrompt(for: session) == nil)
        await store.send("hello again", to: session.id)
        #expect(store.trustPrompt(for: session)?.kind == .refused)

        #expect(store.trustFolder(of: session))
        let retry = try #require(store.trustPrompt(for: session))
        #expect(retry.kind == .retry)
        let before = session.items.count
        await store.sendRefusedMessageAgain(for: session)
        #expect(store.trustNotes.refusals[session.id] == nil)
        #expect(store.trustPrompt(for: session) == nil)
        #expect(session.items.dropFirst(before).contains { if case .user(_, let text, _) = $0 { text == "hello again" } else { false } })
        #expect(!session.items.dropFirst(before).contains { if case .error = $0 { true } else { false } })
    }
    #endif

    // MARK: Private server pieces

    @Test func credentialPlanCopiesKeysAndExternalOnly() {
        func entry(_ id: String, _ integration: String, _ type: String, active: Bool, key: String = "k") -> JSONValue {
            var value: [String: JSONValue] = ["type": .string(type)]
            if type == "key" { value["key"] = .string(key) }
            if type == "oauth" { value.merge(["methodID": "m", "refresh": "r", "access": "a", "expires": 1]) { _, new in new } }
            if type == "external" { value["methodID"] = "profile" }
            return ["id": .string(id), "integrationID": .string(integration), "label": "L", "active": .bool(active), "value": .object(value)]
        }
        let source = [entry("c1", "openai", "key", active: true), entry("c2", "xai", "oauth", active: true),
                      entry("c3", "amazon-bedrock", "external", active: true), entry("c4", "openai", "key", active: false, key: "old")]
        let first = PrivateOpenCodeServer.credentialPlan(source: source, target: [])
        #expect(first.remove.isEmpty)
        #expect(first.create.compactMap { $0["id"]?.stringValue } == ["c4", "c1", "c3"])
        #expect(first.create.allSatisfy { $0["value"]?["type"]?.stringValue != "oauth" })
        #expect(first.create.first { $0["id"] == "c1" }?["activate"] == .bool(true))

        // In step: nothing to do. Changed, removed or foreign entries are replaced or removed.
        let copied = [entry("c1", "openai", "key", active: true), entry("c3", "amazon-bedrock", "external", active: true),
                      entry("c4", "openai", "key", active: false, key: "old")]
        let same = PrivateOpenCodeServer.credentialPlan(source: source, target: copied)
        #expect(same.create.isEmpty && same.remove.isEmpty)
        let changed = PrivateOpenCodeServer.credentialPlan(
            source: [entry("c1", "openai", "key", active: true, key: "new")],
            target: copied + [entry("c2", "xai", "oauth", active: true)])
        #expect(Set(changed.remove) == ["c1", "c2", "c3", "c4"])
        #expect(changed.create.compactMap { $0["id"]?.stringValue } == ["c1"])
    }

    @Test func serverEnvironmentAlwaysDisablesProjectConfig() {
        let data = URL(fileURLWithPath: "/tmp/ens-private")
        let env = PrivateOpenCodeServer.environment(
            base: ["PATH": "/usr/bin", "OPENCODE_DB": "/shared.db", "XDG_DATA_HOME": "/shared", "OPENCODE_SERVER_PASSWORD": "old", "HOME": "/h"],
            dataDirectory: data, password: "secret", executable: URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
            extra: ["OPENCODE_DISABLE_PROJECT_CONFIG": "0", "OPENCODE_CONFIG": "/tmp/user.json"])
        #expect(env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(env["OPENCODE_CONFIG_PROJECT_DISABLE"] == "1")
        #expect(env["OPENCODE_DB"] == nil)
        #expect(env["OPENCODE_SERVER_PASSWORD"] == "secret")
        #expect(env["XDG_DATA_HOME"] == "/tmp/ens-private/data")
        #expect(env["XDG_STATE_HOME"] == "/tmp/ens-private/state")
        #expect(env["OPENCODE_CONFIG"] == "/tmp/user.json")
        #expect(env["HOME"] == "/h")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(PrivateOpenCodeServer.randomPassword().count == 64)
        #expect(PrivateOpenCodeServer.randomPassword() != PrivateOpenCodeServer.randomPassword())
    }

    @Test func listeningAddressIsLoopbackOnly() {
        #expect(PrivateOpenCodeServer.listeningURL(in: "ensemble-private-pid 12\nServer listening on http://127.0.0.1:63604\n")
                == URL(string: "http://127.0.0.1:63604"))
        #expect(PrivateOpenCodeServer.listeningURL(in: "Server listening on http://0.0.0.0:4096") == nil)
        #expect(PrivateOpenCodeServer.listeningURL(in: "Server listening on http://127.0.0.1") == nil)
        #expect(PrivateOpenCodeServer.listeningURL(in: "starting") == nil)
    }
}
