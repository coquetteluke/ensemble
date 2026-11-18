import Foundation

/// Sample state for `DemoRemoteHost`, tests and SwiftUI previews.
public struct RemoteDemoData: Sendable {
    public var sessions: [SessionSummary]
    public var permissions: [PermissionRequest]
    public var transcripts: [String: RemoteTranscript]
    public var rooms: [RemoteRoom]
    public var usage: RemoteUsageSummary

    public init(sessions: [SessionSummary], permissions: [PermissionRequest], transcripts: [String: RemoteTranscript],
                rooms: [RemoteRoom], usage: RemoteUsageSummary) {
        self.sessions = sessions
        self.permissions = permissions
        self.transcripts = transcripts
        self.rooms = rooms
        self.usage = usage
    }

    /// Fixed ids so tests can refer to them.
    public enum IDs {
        public static let fixSession = "demo-fix-login"
        public static let docsSession = "demo-docs"
        public static let oldSession = "demo-old"
        public static let roomSession = "demo-room-api"
        public static let roomID = UUID(uuidString: "6F1D1E9A-2B7C-4C55-9E1A-6B0C8F3A2D11")!
        public static let permission = "demo-perm-1"
        public static let agentA = UUID(uuidString: "0B5E7C1A-1111-4E2B-9C3D-2A6F8E9B0C01")!
        public static let agentB = UUID(uuidString: "0B5E7C1A-2222-4E2B-9C3D-2A6F8E9B0C02")!
    }

    public static func sample(now: Date = Date()) -> RemoteDemoData {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour

        let agentA = RemoteAgent(id: IDs.agentA, name: "Ada", model: "anthropic/claude-opus-5.5", colorHex: "#D97757",
                                 activity: .working, sessionID: "demo-room-ada")
        let agentB = RemoteAgent(id: IDs.agentB, name: "Grace", model: "openai/gpt-6", colorHex: "#6A9BCC",
                                 activity: .idle, sessionID: "demo-room-grace")

        let permission = PermissionRequest(id: IDs.permission, sessionID: IDs.fixSession, kind: "bash",
                                           title: "npm test -- --watch=false",
                                           detail: "Runs the test suite in the project folder.",
                                           created: now.addingTimeInterval(-4 * minute))

        let sessions: [SessionSummary] = [
            SessionSummary(id: IDs.fixSession, title: "Fix login redirect loop", directory: "/Users/demo/code/webapp",
                           agentNames: ["Ada"], activity: .waitingForPermission, lastActivity: now.addingTimeInterval(-4 * minute),
                           pendingAsk: "Approve: npm test", pendingPermissions: 1,
                           usage: Usage(inputTokens: 48_200, outputTokens: 6_100, costUSD: 0.42)),
            SessionSummary(id: IDs.roomSession, title: "Design the sync API", directory: "/Users/demo/code/notes",
                           roomID: IDs.roomID, agentNames: ["Ada", "Grace"], activity: .working,
                           lastActivity: now.addingTimeInterval(-1 * minute),
                           usage: Usage(inputTokens: 120_400, outputTokens: 18_900, costUSD: 1.37)),
            SessionSummary(id: IDs.docsSession, title: "Write README install steps", directory: "/Users/demo/code/notes",
                           agentNames: ["Grace"], activity: .idle, lastActivity: now.addingTimeInterval(-3 * hour),
                           usage: Usage(inputTokens: 9_800, outputTokens: 2_300, costUSD: 0.08)),
            SessionSummary(id: IDs.oldSession, title: "Try the new chart library", directory: "/Users/demo/code/dashboard",
                           agentNames: ["Ada"], activity: .idle, lastActivity: now.addingTimeInterval(-9 * day),
                           usage: Usage(inputTokens: 3_000, outputTokens: 800, costUSD: 0.02)),
        ]

        let fixTranscript = RemoteTranscript(
            sessionID: IDs.fixSession, title: "Fix login redirect loop",
            items: [
                .user(id: "u1", text: "Users get stuck in a redirect loop after logging in. Find out why and fix it.",
                      date: now.addingTimeInterval(-12 * minute)),
                .agentText(id: "a1", text: "I'll look at the auth middleware and the session cookie settings first.",
                           agentID: nil, streaming: false),
                .tool(ToolCallInfo(id: "t1", name: "grep", title: "redirect( in src/", status: .succeeded,
                                   outputPreview: "src/middleware/auth.ts:41")),
                .tool(ToolCallInfo(id: "t2", name: "read", title: "src/middleware/auth.ts", status: .succeeded)),
                .agentText(id: "a2", text: "The middleware redirects to `/login` when the cookie is missing, but the cookie is set with `SameSite=Strict`, so the browser drops it on the redirect back from the identity provider. I changed it to `Lax`.",
                           agentID: nil, streaming: false),
                .tool(ToolCallInfo(id: "t3", name: "edit", title: "src/middleware/auth.ts", status: .succeeded,
                                   diff: "-  sameSite: 'strict',\n+  sameSite: 'lax',")),
                .permission(permission),
            ],
            activity: .waitingForPermission, permissionMode: .ask, agents: [agentA])

        let roomTranscript = RemoteTranscript(
            sessionID: IDs.roomSession, title: "Design the sync API",
            items: [
                .user(id: "ru1", text: "Agree on a sync API for the notes app: REST or WebSocket? Then build it.",
                      date: now.addingTimeInterval(-30 * minute)),
                .notice(id: "rn1", text: "Ada leads. Round table started."),
                .board(id: "rb1", fromAgentID: IDs.agentA, toAgentIDs: [IDs.agentB],
                       text: "I suggest REST for writes and a WebSocket for change notifications.",
                       date: now.addingTimeInterval(-20 * minute)),
                .board(id: "rb2", fromAgentID: IDs.agentB, toAgentIDs: [IDs.agentA],
                       text: "Agreed. Conflict handling: last write wins per field, with a version number.",
                       date: now.addingTimeInterval(-18 * minute)),
                .agentText(id: "ra1", text: "Plan agreed. I'm writing the server routes now; Grace reviews each step.",
                           agentID: IDs.agentA, streaming: false),
                .tool(ToolCallInfo(id: "rt1", name: "edit", title: "server/routes/sync.ts", status: .running)),
            ],
            activity: .working, permissionMode: .acceptEdits, roomID: IDs.roomID, agents: [agentA, agentB])

        let docsTranscript = RemoteTranscript(
            sessionID: IDs.docsSession, title: "Write README install steps",
            items: [
                .user(id: "du1", text: "Add install steps to the README.", date: now.addingTimeInterval(-4 * hour)),
                .tool(ToolCallInfo(id: "dt1", name: "edit", title: "README.md", status: .succeeded)),
                .agentText(id: "da1", text: "Added an Install section with the Homebrew command and first-run steps.",
                           agentID: nil, streaming: false),
            ],
            activity: .idle, permissionMode: .auto, agents: [agentB])

        let oldTranscript = RemoteTranscript(
            sessionID: IDs.oldSession, title: "Try the new chart library",
            items: [.user(id: "ou1", text: "Try the new chart library on the dashboard.", date: now.addingTimeInterval(-9 * day))],
            activity: .idle, permissionMode: .ask, agents: [agentA])

        let room = RemoteRoom(id: IDs.roomID, title: "Design the sync API", directory: "/Users/demo/code/notes",
                              mode: .roundTable, agents: [agentA, agentB], leadAgentID: IDs.agentA, state: .running,
                              permissionMode: .acceptEdits, sessionID: IDs.roomSession,
                              usage: Usage(inputTokens: 120_400, outputTokens: 18_900, costUSD: 1.37),
                              lastActivity: now.addingTimeInterval(-1 * minute))

        let usage = RemoteUsageSummary(
            today: Usage(inputTokens: 178_400, outputTokens: 27_300, costUSD: 1.87),
            week: Usage(inputTokens: 1_204_000, outputTokens: 190_500, costUSD: 12.40),
            providers: [
                .init(id: "anthropic", label: "Anthropic", usage: Usage(inputTokens: 130_000, outputTokens: 19_000, costUSD: 1.41)),
                .init(id: "openai", label: "OpenAI", usage: Usage(inputTokens: 48_400, outputTokens: 8_300, costUSD: 0.46)),
            ],
            agents: [
                .init(id: IDs.agentA.uuidString, label: "Ada", usage: Usage(inputTokens: 130_000, outputTokens: 19_000, costUSD: 1.41),
                      capUSD: 5, colorHex: "#D97757"),
                .init(id: IDs.agentB.uuidString, label: "Grace", usage: Usage(inputTokens: 48_400, outputTokens: 8_300, costUSD: 0.46),
                      capUSD: nil, colorHex: "#6A9BCC"),
            ],
            updated: now)

        return RemoteDemoData(
            sessions: sessions, permissions: [permission],
            transcripts: [IDs.fixSession: fixTranscript, IDs.roomSession: roomTranscript,
                          IDs.docsSession: docsTranscript, IDs.oldSession: oldTranscript],
            rooms: [room], usage: usage)
    }
}
