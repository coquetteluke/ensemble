import Foundation

/// Sample state for `DemoRemoteHost`, tests and SwiftUI previews.
public struct RemoteDemoData: Sendable {
    public var sessions: [SessionSummary]
    public var permissions: [PermissionRequest]
    public var transcripts: [String: RemoteTranscript]
    public var rooms: [RemoteRoom]
    public var usage: RemoteUsageSummary
    public var availableModels: [RemoteModelOption]
    public var recentFolders: [String]
    public var diffs: [String: RemoteSessionDiff]
    public var details: [String: RemoteSessionDetails]

    public init(sessions: [SessionSummary], permissions: [PermissionRequest], transcripts: [String: RemoteTranscript],
                rooms: [RemoteRoom], usage: RemoteUsageSummary,
                availableModels: [RemoteModelOption] = [],
                recentFolders: [String] = [],
                diffs: [String: RemoteSessionDiff] = [:],
                details: [String: RemoteSessionDetails] = [:]) {
        self.sessions = sessions
        self.permissions = permissions
        self.transcripts = transcripts
        self.rooms = rooms
        self.usage = usage
        self.availableModels = availableModels
        self.recentFolders = recentFolders
        self.diffs = diffs
        self.details = details
    }

    /// The Mac's name in demo mode.
    public static let macName = "Demo Mac"

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
        public static let agentC = UUID(uuidString: "0B5E7C1A-3333-4E2B-9C3D-2A6F8E9B0C03")!
        public static let teamRoomID = UUID(uuidString: "6F1D1E9A-2B7C-4C55-9E1A-6B0C8F3A2D22")!
        public static let roomPermission = "demo-room-perm-lint"
        public static let roomLongPermission = "demo-room-perm-migrate"
        public static let planDecision = "approvePlan-demo"
        public static let fixOpinion = UUID(uuidString: "9C1A2B3C-4D5E-4F6A-8B7C-1D2E3F4A5B6C")!
    }

    public static func sample(now: Date = Date()) -> RemoteDemoData {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour

        let availableModels: [RemoteModelOption] = [
            RemoteModelOption(providerID: "claude-code", modelID: "opus", name: "Claude Opus 5.5",
                              makerName: "Claude", engineLabel: "Claude (your subscription)"),
            RemoteModelOption(providerID: "claude-code", modelID: "sonnet", name: "Claude Sonnet 5.5",
                              makerName: "Claude", engineLabel: "Claude (your subscription)"),
            RemoteModelOption(providerID: "claude-code", modelID: "haiku", name: "Claude Haiku 5.5",
                              makerName: "Claude", engineLabel: "Claude (your subscription)"),
            RemoteModelOption(providerID: "antigravity", modelID: "gemini-3-pro", name: "Gemini 3 Pro",
                              makerName: "Gemini", engineLabel: "Google AI"),
            RemoteModelOption(providerID: "antigravity", modelID: "gemini-3-flash", name: "Gemini 3 Flash",
                              makerName: "Gemini", engineLabel: "Google AI"),
            RemoteModelOption(providerID: "openai", modelID: "gpt-6", name: "GPT-6",
                              makerName: "ChatGPT", engineLabel: "OpenAI"),
            RemoteModelOption(providerID: "xai", modelID: "grok-4.7", name: "Grok 4.7",
                              makerName: "Grok", engineLabel: "xAI"),
        ]

        let recentFolders = [
            "/Users/demo/code/webapp",
            "/Users/demo/code/notes",
            "/Users/demo/code/dashboard",
            "/Users/demo/code/api-server",
        ]

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
                           usage: Usage(inputTokens: 48_200, outputTokens: 6_100, costUSD: 0.42),
                           modelProviderID: "claude-code", modelID: "opus"),
            SessionSummary(id: IDs.roomSession, title: "Design the sync API", directory: "/Users/demo/code/notes",
                           roomID: IDs.roomID, agentNames: ["Ada", "Grace"], activity: .working,
                           lastActivity: now.addingTimeInterval(-1 * minute),
                           usage: Usage(inputTokens: 120_400, outputTokens: 18_900, costUSD: 1.37)),
            SessionSummary(id: IDs.docsSession, title: "Write README install steps", directory: "/Users/demo/code/notes",
                           agentNames: ["Grace"], activity: .idle, lastActivity: now.addingTimeInterval(-3 * hour),
                           usage: Usage(inputTokens: 9_800, outputTokens: 2_300, costUSD: 0.08),
                           modelProviderID: "openai", modelID: "gpt-6"),
            SessionSummary(id: IDs.oldSession, title: "Try the new chart library", directory: "/Users/demo/code/dashboard",
                           agentNames: ["Ada"], activity: .idle, lastActivity: now.addingTimeInterval(-9 * day),
                           usage: Usage(inputTokens: 3_000, outputTokens: 800, costUSD: 0.02),
                           modelProviderID: "claude-code", modelID: "sonnet"),
        ]

        let fixOpinion = RemoteSecondOpinion(
            id: IDs.fixOpinion,
            itemID: "a2",
            modelName: "GPT-6",
            makerName: "ChatGPT",
            status: "ready",
            verdict: "mixed",
            summary: "Switching SameSite to Lax fixes the OAuth redirect loop, though state validation and cookie expiry still need checks.",
            concerns: [
                "Verify the OAuth callback validates the state parameter against a signed nonce before issuing the session cookie.",
                "Ensure secure: true remains enabled behind TLS termination in production."
            ],
            details: """
            VERDICT: MIXED
            SUMMARY: Switching SameSite to Lax fixes the OAuth redirect loop, though state validation and cookie expiry still need checks.
            CONCERNS:
            - Verify the OAuth callback validates the state parameter against a signed nonce before issuing the session cookie.
            - Ensure secure: true remains enabled behind TLS termination in production.
            DETAILS:
            `SameSite=Strict` blocks top-level cross-site GET redirects from the identity provider, which explains the redirect loop. Setting `SameSite=Lax` allows the session cookie on the return redirect while still protecting state-changing POST requests.
            """
        )

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
            activity: .waitingForPermission, permissionMode: .ask, agents: [agentA],
            modelProviderID: "claude-code", modelID: "opus", secondOpinions: [fixOpinion])

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
            activity: .idle, permissionMode: .auto, agents: [agentB],
            modelProviderID: "openai", modelID: "gpt-6")

        let oldTranscript = RemoteTranscript(
            sessionID: IDs.oldSession, title: "Try the new chart library",
            items: [.user(id: "ou1", text: "Try the new chart library on the dashboard.", date: now.addingTimeInterval(-9 * day))],
            activity: .idle, permissionMode: .ask, agents: [agentA],
            modelProviderID: "claude-code", modelID: "sonnet")

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
            updated: now,
            plans: [
                RemotePlanUsage(id: SubscriptionPlan.claude.id, title: SubscriptionPlan.claude.title, windows: [
                    .init(id: "five_hour", label: "Five-hour limit", usedFraction: 0.46, resetsAt: now.addingTimeInterval(137 * minute)),
                    .init(id: "seven_day", label: "Weekly limit", usedFraction: 0.71, resetsAt: now.addingTimeInterval(77 * 60 * minute)),
                ]),
                RemotePlanUsage(id: SubscriptionPlan.googleAI.id, title: SubscriptionPlan.googleAI.title, windows: [
                    .init(id: "gemini/5h", group: "Gemini models", label: "Five-hour limit", usedFraction: 0.62,
                          resetsAt: now.addingTimeInterval(160 * minute)),
                    .init(id: "gemini/weekly", group: "Gemini models", label: "Weekly limit", usedFraction: 0.19,
                          resetsAt: now.addingTimeInterval(99 * 60 * minute)),
                    .init(id: "3p/5h", group: "Claude and GPT models", label: "Five-hour limit", usedFraction: 0),
                    .init(id: "3p/weekly", group: "Claude and GPT models", label: "Weekly limit", usedFraction: 0),
                ]),
            ])

        let fixDiff = RemoteSessionDiff(
            sessionID: IDs.fixSession,
            directory: "/Users/demo/code/webapp",
            files: [
                RemoteDiffFile(
                    path: "src/middleware/auth.ts",
                    status: "modified",
                    additions: 4,
                    deletions: 2,
                    diffText: """
                    diff --git a/src/middleware/auth.ts b/src/middleware/auth.ts
                    --- a/src/middleware/auth.ts
                    +++ b/src/middleware/auth.ts
                    @@ -38,9 +38,11 @@ export function issueSessionCookie(res: Response, token: string) {
                       res.cookie('session', token, {
                         httpOnly: true,
                    -    secure: true,
                    -    sameSite: 'strict',
                    +    secure: process.env.NODE_ENV === 'production',
                    +    sameSite: 'lax',
                         path: '/',
                    +    maxAge: 7 * 24 * 60 * 60 * 1000,
                       });
                     }
                    """
                ),
                RemoteDiffFile(
                    path: "src/routes/login.ts",
                    status: "modified",
                    additions: 5,
                    deletions: 1,
                    diffText: """
                    diff --git a/src/routes/login.ts b/src/routes/login.ts
                    --- a/src/routes/login.ts
                    +++ b/src/routes/login.ts
                    @@ -22,6 +22,10 @@ router.get('/callback', async (req, res) => {
                       const token = await exchangeCode(String(req.query.code));
                       issueSessionCookie(res, token);
                    -  res.redirect('/dashboard');
                    +  const next = sanitizeRedirect(req.query.state);
                    +  res.redirect(next ?? '/dashboard');
                     });
                    """
                ),
                RemoteDiffFile(
                    path: "tests/auth-redirect.test.ts",
                    status: "added",
                    additions: 12,
                    deletions: 0,
                    diffText: """
                    diff --git a/tests/auth-redirect.test.ts b/tests/auth-redirect.test.ts
                    new file mode 100644
                    --- /dev/null
                    +++ b/tests/auth-redirect.test.ts
                    @@ -0,0 +1,12 @@
                    +import { expect, test } from 'vitest';
                    +import { issueSessionCookie } from '../src/middleware/auth';
                    +
                    +test('sets SameSite=Lax so OAuth redirects keep the cookie', () => {
                    +  const cookies: Record<string, any> = {};
                    +  const res = { cookie: (name: string, val: string, opts: any) => { cookies[name] = { val, opts }; } };
                    +  issueSessionCookie(res as any, 'tok_123');
                    +  expect(cookies.session.opts.sameSite).toBe('lax');
                    +  expect(cookies.session.opts.httpOnly).toBe(true);
                    +});
                    """
                ),
            ]
        )

        let roomDiff = RemoteSessionDiff(
            sessionID: IDs.roomSession,
            directory: "/Users/demo/code/notes",
            files: [
                RemoteDiffFile(
                    path: "server/routes/sync.ts",
                    status: "modified",
                    additions: 8,
                    deletions: 2,
                    diffText: """
                    diff --git a/server/routes/sync.ts b/server/routes/sync.ts
                    --- a/server/routes/sync.ts
                    +++ b/server/routes/sync.ts
                    @@ -12,6 +12,12 @@ export function registerSyncRoutes(app: Express) {
                       app.post('/api/sync', async (req, res) => {
                    -    const result = await applyChanges(req.body.changes);
                    -    res.json(result);
                    +    const { changes, clientVersion } = req.body;
                    +    const result = await applyChanges(changes, { expectedVersion: clientVersion });
                    +    broadcastUpdate(result.noteIds);
                    +    res.json(result);
                       });
                     }
                    """
                ),
            ]
        )

        let docsDiff = RemoteSessionDiff(
            sessionID: IDs.docsSession,
            directory: "/Users/demo/code/notes",
            files: [
                RemoteDiffFile(
                    path: "README.md",
                    status: "modified",
                    additions: 6,
                    deletions: 0,
                    diffText: """
                    diff --git a/README.md b/README.md
                    --- a/README.md
                    +++ b/README.md
                    @@ -8,3 +8,9 @@ Notes sync engine.
                    +## Install
                    +
                    +```bash
                    +brew install notes-sync
                    +notes-sync init
                    +```
                    """
                ),
            ]
        )

        return RemoteDemoData(
            sessions: sessions, permissions: [permission],
            transcripts: [IDs.fixSession: fixTranscript, IDs.roomSession: roomTranscript,
                          IDs.docsSession: docsTranscript, IDs.oldSession: oldTranscript],
            rooms: [room], usage: usage,
            availableModels: availableModels,
            recentFolders: recentFolders,
            diffs: [IDs.fixSession: fixDiff, IDs.roomSession: roomDiff, IDs.docsSession: docsDiff],
            details: sampleDetails())
    }

    /// What the details panel shows for each demo session: context around half used, a few changed files and three
    /// connectors in different states.
    static func sampleDetails() -> [String: RemoteSessionDetails] {
        func context(limit: Int, system: Int, tools: Int, mcp: Int, memory: Int, skills: Int, messages: Int,
                     buffer: Int) -> ContextBreakdown {
            let used = system + tools + mcp + memory + skills + messages
            return ContextBreakdown(usedTokens: used, limitTokens: limit, categories: [
                .init(key: "systemPrompt", label: "System prompt", tokens: system),
                .init(key: "tools", label: "Tools", tokens: tools),
                .init(key: "mcp", label: "MCP", tokens: mcp),
                .init(key: "memory", label: "Memory files", tokens: memory),
                .init(key: "skills", label: "Skills", tokens: skills),
                .init(key: "messages", label: "Messages", tokens: messages),
                .init(key: "buffer", label: "Autocompact buffer", tokens: buffer),
                .init(key: "free", label: "Free space", tokens: max(0, limit - used - buffer)),
            ])
        }
        let connectors = [
            ConnectorInfo(id: "github", name: "GitHub", state: .connected, toolCount: 41),
            ConnectorInfo(id: "linear", name: "Linear", state: .needsAuth),
            ConnectorInfo(id: "sentry", name: "Sentry", state: .failed),
        ]
        return [
            IDs.fixSession: RemoteSessionDetails(
                sessionID: IDs.fixSession, macName: macName, directory: "/Users/demo/code/webapp",
                extraFolders: ["/Users/demo/code/shared-auth"],
                context: context(limit: 1_000_000, system: 6_200, tools: 14_800, mcp: 9_400, memory: 3_100, skills: 2_600,
                                 messages: 432_800, buffer: 45_000),
                outputs: [
                    FileChange(path: "src/middleware/auth.ts", kind: .modified, additions: 4, deletions: 2),
                    FileChange(path: "src/routes/login.ts", kind: .modified, additions: 5, deletions: 1),
                    FileChange(path: "tests/auth-redirect.test.ts", kind: .added, additions: 12),
                    FileChange(path: "src/lib/session.ts", kind: .modified, additions: 3, deletions: 3),
                ],
                connectors: connectors),
            IDs.roomSession: RemoteSessionDetails(
                sessionID: IDs.roomSession, macName: macName, directory: "/Users/demo/code/notes",
                context: context(limit: 400_000, system: 5_900, tools: 13_200, mcp: 9_400, memory: 2_400, skills: 1_800,
                                 messages: 178_300, buffer: 20_000),
                outputs: [
                    FileChange(path: "server/routes/sync.ts", kind: .modified, additions: 8, deletions: 2),
                    FileChange(path: "server/sync/merge.ts", kind: .added, additions: 64),
                    FileChange(path: "server/sync/merge.test.ts", kind: .added, additions: 38),
                    FileChange(path: "docs/sync-api.md", kind: .added, additions: 27),
                    FileChange(path: "server/sync/legacy.ts", kind: .deleted, deletions: 41),
                ],
                connectors: connectors),
            IDs.docsSession: RemoteSessionDetails(
                sessionID: IDs.docsSession, macName: macName, directory: "/Users/demo/code/notes",
                context: context(limit: 400_000, system: 5_100, tools: 11_900, mcp: 9_400, memory: 2_400, skills: 1_200,
                                 messages: 148_400, buffer: 20_000),
                outputs: [
                    FileChange(path: "README.md", kind: .modified, additions: 6),
                    FileChange(path: "docs/install.md", kind: .added, additions: 22),
                    FileChange(path: "package.json", kind: .modified, additions: 1, deletions: 1),
                ],
                connectors: connectors),
            IDs.oldSession: RemoteSessionDetails(
                sessionID: IDs.oldSession, macName: macName, directory: "/Users/demo/code/dashboard",
                context: context(limit: 200_000, system: 4_800, tools: 12_600, mcp: 9_400, memory: 1_900, skills: 1_200,
                                 messages: 82_100, buffer: 33_000),
                outputs: [
                    FileChange(path: "src/charts/LineChart.tsx", kind: .added, additions: 58),
                    FileChange(path: "src/pages/Overview.tsx", kind: .modified, additions: 9, deletions: 14),
                    FileChange(path: "package.json", kind: .modified, additions: 1),
                ],
                connectors: connectors),
        ]
    }

    /// `sample` plus what rooms on the phone show: the round table waiting on a short and a long command, and a Team
    /// room waiting for its plan to be approved. Used by the iPhone's demo mode and its screenshots.
    public static func showcase(now: Date = Date()) -> RemoteDemoData {
        var data = sample(now: now)
        let minute: TimeInterval = 60

        let lint = PermissionRequest(id: IDs.roomPermission, sessionID: "demo-room-grace", kind: "bash", title: "npm run lint",
                                     created: now.addingTimeInterval(-2 * minute))
        let migrate = PermissionRequest(
            id: IDs.roomLongPermission, sessionID: "demo-room-ada", kind: "bash",
            title: "psql \"$DATABASE_URL\" <<'SQL'\nALTER TABLE notes ADD COLUMN version integer NOT NULL DEFAULT 0;\nCREATE INDEX notes_updated_at ON notes (updated_at);\nSQL",
            detail: "Adds a version column to the notes table.", created: now.addingTimeInterval(-1 * minute))
        data.permissions += [lint, migrate]
        if var roundTable = data.rooms.first {
            roundTable.permissions = [lint, migrate]
            roundTable.phaseLabel = RoomPhase.building.label
            for i in roundTable.agents.indices { roundTable.agents[i].activity = .waitingForPermission }
            roundTable.goal = RemoteGoal(condition: "the sync API tests pass", active: true, statusLabel: "Run 2 of 5", turns: 2,
                                         maxTurns: 5, costSpentUSD: 0.84, lastReason: "the conflict test still fails")
            roundTable.members = [
                RemoteMember(agentID: IDs.agentA, role: "Builder", state: "waitingOnYou", stateLabel: "Waiting on you",
                             step: "Waiting for permission", costUSD: 0.98),
                RemoteMember(agentID: IDs.agentB, role: "Reviewer", state: "waitingOnYou", stateLabel: "Waiting on you",
                             step: "Waiting for permission", costUSD: 0.39),
            ]
            data.rooms[0] = roundTable
            data.transcripts[IDs.roomSession]?.items += [.permission(lint), .permission(migrate)]
            data.transcripts[IDs.roomSession]?.agents = roundTable.agents
            if let i = data.sessions.firstIndex(where: { $0.id == IDs.roomSession }) {
                var row = RemoteRoomBridge.hubRow(roundTable)
                row.id = IDs.roomSession
                data.sessions[i] = row
            }
        }

        let ada = RemoteAgent(id: IDs.agentA, name: "Ada", model: "anthropic/claude-opus-5.5", colorHex: "#D97757", sessionID: "demo-team-ada")
        let grace = RemoteAgent(id: IDs.agentB, name: "Grace", model: "openai/gpt-6", colorHex: "#6A9BCC", sessionID: "demo-team-grace")
        let linus = RemoteAgent(id: IDs.agentC, name: "Linus", model: "google/gemini-3-pro", colorHex: "#7FB069", sessionID: "demo-team-linus")
        let plan = """
        Keep a local copy of every note in SQLite and sync changes when the network comes back.

        - Conflicts: last write wins per field, using the version number.
        - The sync queue survives app restarts.
        """
        let decision = RemoteRoomDecision(
            id: IDs.planDecision, kind: .approvePlan, title: "The plan is ready", agentID: IDs.agentA, text: plan,
            items: [.init(agentID: IDs.agentA, text: "Local SQLite store and its migrations"),
                    .init(agentID: IDs.agentB, text: "Sync queue with retry and backoff"),
                    .init(agentID: IDs.agentC, text: "Tests for offline edits and conflicts")],
            choices: [RemoteRoomChoice(id: "approve", label: "Approve", style: .primary),
                      RemoteRoomChoice(id: "redo", label: "Redo", input: .optional, placeholder: "What should change (optional)")])
        let team = RemoteRoom(id: IDs.teamRoomID, title: "Add offline sync", directory: "/Users/demo/code/notes", mode: .team,
                              agents: [ada, grace, linus], leadAgentID: IDs.agentA, state: .idle, permissionMode: .ask,
                              sessionID: IDs.teamRoomID.uuidString,
                              usage: Usage(inputTokens: 42_000, outputTokens: 5_600, costUSD: 0.51),
                              lastActivity: now.addingTimeInterval(-6 * minute),
                              phaseLabel: RoomPhase.awaitingApproval.label, decision: decision,
                              members: [
                                  RemoteMember(agentID: IDs.agentA, role: "Lead", state: "waitingOnYou", stateLabel: "Waiting on you",
                                               step: "Waiting for you to approve the plan", costUSD: 0.33),
                                  RemoteMember(agentID: IDs.agentB, role: "Builder", state: "standingBy", stateLabel: "Standing by",
                                               step: "Assigned: Sync queue with retry and backoff", costUSD: 0.12),
                                  RemoteMember(agentID: IDs.agentC, role: "Builder", state: "standingBy", stateLabel: "Standing by",
                                               step: "Assigned: Tests for offline edits and conflicts", costUSD: 0.06),
                              ])
        data.rooms.append(team)
        data.sessions.append(RemoteRoomBridge.hubRow(team))
        data.transcripts[team.sessionID] = RemoteTranscript(
            sessionID: team.sessionID, title: team.title,
            items: [
                .user(id: "tu1", text: "Add offline sync to the notes app.", date: now.addingTimeInterval(-14 * minute)),
                .notice(id: "tn1", text: "Ada leads. Team started."),
                .board(id: "tb1", fromAgentID: IDs.agentA, toAgentIDs: [],
                       text: "PLAN: " + plan + "\n\nASSIGN @Ada: Local SQLite store and its migrations\nASSIGN @Grace: Sync queue with retry and backoff\nASSIGN @Linus: Tests for offline edits and conflicts",
                       date: now.addingTimeInterval(-6 * minute)),
                .notice(id: "tn2", text: "The plan is ready. Approve, edit or redo it."),
            ],
            activity: .idle, permissionMode: .ask, roomID: team.id, agents: team.agents)
        return data
    }
}
