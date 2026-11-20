import Foundation

/// Sample projects, sessions and transcripts for the preview engine, SwiftUI previews and snapshots.
public enum PreviewData {
    public static let mainSessionID = "ses_context_panel"
    public static let childSessionID = "ses_colour_check"
    public static let pendingTestsPermissionID = "perm_tests"

    public static let opusAgentID = UUID(uuidString: "6A1C1E0B-4B4E-4E0C-9C1A-000000000001")!
    public static let gptAgentID = UUID(uuidString: "6A1C1E0B-4B4E-4E0C-9C1A-000000000002")!
    public static let grokAgentID = UUID(uuidString: "6A1C1E0B-4B4E-4E0C-9C1A-000000000003")!

    static let opus = ModelRef(providerID: "anthropic", id: "claude-opus-5-5")
    static let sonnet = ModelRef(providerID: "anthropic", id: "claude-sonnet-5")
    static let gpt = ModelRef(providerID: "openai", id: "gpt-5.5")
    static let grok = ModelRef(providerID: "xai", id: "grok-5")

    public static func seed(now: Date = Date()) -> StoreSeed {
        let home = NSHomeDirectory()
        let ensemble = home + "/Ensemble"
        let portfolio = home + "/Developer/portfolio-site"
        let api = home + "/Developer/api-server"
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

        // MARK: Sessions
        let sessions: [EngineSession] = [
            EngineSession(id: mainSessionID, title: "Build the context panel", directory: ensemble, model: opus,
                          usage: Usage(inputTokens: 412_000, outputTokens: 18_400, reasoningTokens: 6_100,
                                       cacheReadTokens: 1_240_000, cacheWriteTokens: 96_000, costUSD: 2.84),
                          created: ago(3600 * 2), updated: ago(120)),
            EngineSession(id: childSessionID, parentID: mainSessionID, title: "Check the panel colours against the reference",
                          directory: ensemble, model: sonnet, agent: "general",
                          usage: Usage(inputTokens: 38_000, outputTokens: 1_900, costUSD: 0.14),
                          created: ago(900), updated: ago(840)),
            EngineSession(id: "ses_sse_reconnect", title: "Fix SSE reconnect after sleep", directory: ensemble, model: gpt,
                          usage: Usage(inputTokens: 96_000, outputTokens: 4_200, costUSD: 0.61),
                          created: ago(1800), updated: ago(30)),
            EngineSession(id: "ses_db_debate", title: "SQLite or Postgres for sync", directory: ensemble, model: opus,
                          usage: Usage(inputTokens: 64_000, outputTokens: 9_800, costUSD: 0.92),
                          created: ago(3600 * 2), updated: ago(3600)),
            EngineSession(id: "ses_readme", title: "Write the README", directory: ensemble, model: sonnet,
                          usage: Usage(inputTokens: 41_000, outputTokens: 3_100, costUSD: 0.22),
                          created: ago(3600 * 4), updated: ago(3600 * 3)),
            EngineSession(id: "ses_dark_mode", title: "Add a dark mode toggle", directory: portfolio, model: sonnet,
                          usage: Usage(inputTokens: 52_000, outputTokens: 2_700, costUSD: 0.31),
                          created: ago(3600), updated: ago(720)),
            EngineSession(id: "ses_astro", title: "Migrate to Astro 5", directory: portfolio, model: gpt,
                          usage: Usage(inputTokens: 210_000, outputTokens: 12_000, costUSD: 1.47),
                          created: ago(86_400 * 2 + 3600), updated: ago(86_400 * 2)),
            EngineSession(id: "ses_rate_limit", title: "Rate limiter tests", directory: api, model: gpt,
                          usage: Usage(inputTokens: 33_000, outputTokens: 1_400, costUSD: 0.18),
                          created: ago(86_400 * 4 + 600), updated: ago(86_400 * 4)),
        ]

        // MARK: Main transcript
        let testsPermission = PermissionRequest(
            id: pendingTestsPermissionID, sessionID: mainSessionID, kind: "bash", title: "swift test --parallel",
            detail: "Runs the EnsembleKit test suite in ~/Ensemble/Packages/EnsembleKit.", alwaysPatterns: ["swift test *"], created: ago(110))

        let contextBarDiff = """
        --- a/Apps/Mac/ContextPanel/ContextBar.swift
        +++ b/Apps/Mac/ContextPanel/ContextBar.swift
        @@ -8,11 +8,19 @@ struct ContextBar: View {
             let breakdown: ContextBreakdown
        -    let height: CGFloat = 6
        +    let height: CGFloat = 4

             var body: some View {
                 GeometryReader { proxy in
        -            Capsule().fill(.blue)
        -                .frame(width: proxy.size.width * breakdown.fractionUsed)
        +            HStack(spacing: 1) {
        +                ForEach(segments) { segment in
        +                    Rectangle()
        +                        .fill(segment.color)
        +                        .frame(width: max(2, segment.fraction * proxy.size.width))
        +                }
        +                Spacer(minLength: 0)
        +            }
        +            .background(Capsule().fill(Color(hex: 0x2B2B2B)))
        +            .clipShape(Capsule())
                 }
                 .frame(height: height)
             }
         }
        """

        let summary = """
        The panel is in place and builds cleanly. What changed:

        ## Context bar

        - Each category gets a segment sized by its share of the **limit**, not of the used tokens.
        - Segments sit 1 pt apart so the small ones stay visible.
        - `Autocompact buffer` is drawn in grey and free space is the track.

        ```swift
        let fraction = Double(category.tokens) / Double(breakdown.limitTokens)
        let width = max(2, fraction * proxy.size.width)
        ```

        I'd like to run the tests before I touch the Outputs list.
        """

        let mainItems: [TranscriptItem] = [
            .user(id: "u1", text: "Build the right-hand context panel. Match the reference: Environment, Context with the coloured bar and breakdown rows, Outputs and Connectors.", date: ago(3600)),
            .tool(ToolCallInfo(id: "t_plan", name: "todowrite", title: "Plan",
                               inputJSON: #"{"todos": [{"content": "Read the context model and the store", "status": "completed"}, {"content": "Build the segmented context bar", "status": "completed"}, {"content": "Run the EnsembleKit tests", "status": "in_progress", "activeForm": "Running the EnsembleKit tests"}, {"content": "Fill in the Outputs list with file icons", "status": "pending"}, {"content": "Show connector status and Authenticate", "status": "pending"}]}"#,
                               status: .succeeded)),
            .reasoning(id: "r1", text: "The panel has four sections. The numbers come from `engine.context()`, so I should read `ContextBreakdown` first, then check how the store exposes the selected session.", streaming: false),
            .agentText(id: "a1", text: "I'll start with the model types and the store.", agentID: nil, streaming: false),
            .tool(ToolCallInfo(id: "t_read", name: "read", title: ensemble + "/Packages/EnsembleKit/Sources/EnsembleKit/Model/Context.swift",
                               inputJSON: #"{"filePath": "Packages/EnsembleKit/Sources/EnsembleKit/Model/Context.swift"}"#,
                               status: .succeeded,
                               outputPreview: "import Foundation\n\n/// Context window use for the right-hand panel.\npublic struct ContextBreakdown: Codable, Hashable, Sendable {\n    public var usedTokens: Int\n    public var limitTokens: Int\n    public var categories: [Category]\n}")),
            .tool(ToolCallInfo(id: "t_grep", name: "grep", title: "ContextBreakdown",
                               inputJSON: #"{"pattern": "ContextBreakdown", "path": "."}"#, status: .succeeded,
                               outputPreview: "Packages/EnsembleKit/Sources/EnsembleKit/Model/Context.swift:4\nPackages/EnsembleKit/Sources/EnsembleKit/Store/SessionStore.swift:212\nApps/Mac/ContextPanel/ContextPanelView.swift:31")),
            .tool(ToolCallInfo(id: "t_task", name: "task", title: "Check the panel colours against the reference",
                               inputJSON: #"{"description": "Check the panel colours against the reference", "subagent_type": "general"}"#,
                               status: .succeeded,
                               outputPreview: "All four category colours match. The free space track should be #2B2B2B.",
                               childSessionID: childSessionID)),
            .tool(ToolCallInfo(id: "t_edit", name: "edit", title: ensemble + "/Apps/Mac/ContextPanel/ContextBar.swift",
                               inputJSON: #"{"filePath": "Apps/Mac/ContextPanel/ContextBar.swift"}"#, status: .succeeded,
                               diff: contextBarDiff)),
            .tool(ToolCallInfo(id: "t_build", name: "bash", title: "swift build",
                               inputJSON: #"{"command": "swift build", "description": "Build the package"}"#, status: .succeeded,
                               outputPreview: "Building for debugging...\n[14/14] Compiling EnsembleKit ContextBar.swift\nBuild complete! (4.21s)")),
            .agentText(id: "a2", text: summary, agentID: nil, streaming: false),
            .permission(testsPermission),
        ]

        let childItems: [TranscriptItem] = [
            .user(id: "cu1", text: "Compare the context panel colours with the reference screenshot and list any mismatches.", date: ago(900)),
            .tool(ToolCallInfo(id: "ct_read", name: "read", title: ensemble + "/Apps/Mac/ContextPanel/ContextPanelView.swift",
                               status: .succeeded, outputPreview: "struct ContextPanelView: View {\n    let session: SessionModel?\n    ...")),
            .agentText(id: "ca1", text: """
            All four category colours match the reference:

            | Category | Colour |
            |---|---|
            | Messages | `#328CF0` |
            | MCP tools | `#E66624` |
            | System tools | `#04A887` |
            | System prompt | `#D38E05` |

            The free space track was one shade too light. Use `#2B2B2B`.
            """, agentID: nil, streaming: false),
        ]

        let sseItems: [TranscriptItem] = [
            .user(id: "su1", text: "The event stream drops after the laptop sleeps. Make it reconnect with backoff.", date: ago(1800)),
            .reasoning(id: "sr1", text: "URLSession fails the stream task on wake. I need a retry loop with capped exponential backoff and a reset after a good event.", streaming: false),
            .agentText(id: "sa1", text: "The stream task fails with `NSURLErrorNetworkConnectionLost` on wake and nothing restarts it. I'll add a retry loop with capped backoff.", agentID: nil, streaming: false),
            .tool(ToolCallInfo(id: "st_edit", name: "edit", title: ensemble + "/Packages/EnsembleKit/Sources/EnsembleKit/OpenCode/EventStream.swift",
                               status: .succeeded, diff: "@@ -40,6 +40,14 @@\n     func run() async {\n-        await connectOnce()\n+        var delay: Duration = .milliseconds(250)\n+        while !Task.isCancelled {\n+            if await connectOnce() { delay = .milliseconds(250) }\n+            try? await Task.sleep(for: delay)\n+            delay = min(delay * 2, .seconds(10))\n+        }\n     }")),
            .tool(ToolCallInfo(id: "st_test", name: "bash", title: "swift test --filter EventStreamTests",
                               inputJSON: #"{"command": "swift test --filter EventStreamTests"}"#, status: .running,
                               outputPreview: "Building for debugging...\n[6/9] Compiling EnsembleKitTests EventStreamTests.swift")),
        ]

        let readmeItems: [TranscriptItem] = [
            .user(id: "ru1", text: "Write a README with build steps and a short feature list.", date: ago(3600 * 4)),
            .tool(ToolCallInfo(id: "rt_write", name: "write", title: ensemble + "/README.md", status: .succeeded,
                               diff: "@@ -0,0 +1,6 @@\n+# Ensemble\n+\n+Code with several AI models at once.\n+\n+## Build\n+Run `xcodegen`, then build the Ensemble scheme.")),
            .agentText(id: "ra1", text: "The README now covers what Ensemble is, how to build it, and where the docs live.", agentID: nil, streaming: false),
        ]

        let darkModePermission = PermissionRequest(
            id: "perm_theme_toggle", sessionID: "ses_dark_mode", kind: "edit", title: "src/components/ThemeToggle.tsx",
            detail: "Create a toggle that stores the choice in localStorage and sets data-theme on <html>.", created: ago(720))
        let darkModeItems: [TranscriptItem] = [
            .user(id: "du1", text: "Add a dark mode toggle to the header. Remember the choice.", date: ago(3600)),
            .agentText(id: "da1", text: "I'll add a `ThemeToggle` component and wire it into the header.", agentID: nil, streaming: false),
            .permission(darkModePermission),
        ]

        let astroItems: [TranscriptItem] = [
            .user(id: "au1", text: "Upgrade the site to Astro 5 and fix anything that breaks.", date: ago(86_400 * 2 + 3600)),
            .tool(ToolCallInfo(id: "at_install", name: "bash", title: "npm install astro@5", status: .succeeded,
                               outputPreview: "added 12 packages, changed 31 packages in 9s")),
            .agentText(id: "aa1", text: "Astro 5 is installed and the build passes. Two content collections moved to the new loader API.", agentID: nil, streaming: false),
        ]

        let rateItems: [TranscriptItem] = [
            .user(id: "lu1", text: "Write tests for the token bucket rate limiter.", date: ago(86_400 * 4 + 600)),
            .tool(ToolCallInfo(id: "lt_test", name: "bash", title: "go test ./ratelimit/...", status: .failed,
                               outputPreview: "--- FAIL: TestBucketRefill (0.00s)\n    bucket_test.go:41: got 4 tokens, want 5")),
            .error(id: "le1", message: "Provider error: rate limit reached for gpt-5.5 (429). Try again in 20 s."),
        ]

        let debateItems: [TranscriptItem] = [
            .user(id: "bu1", text: "Should the sync service use SQLite or Postgres? Argue it out and give me a decision.", date: ago(3600 * 2)),
            .notice(id: "bn1", text: "Debate started: 3 agents, 2 rounds"),
            .agentText(id: "ba1", text: "**SQLite.** Every client already ships it, there is no server to run, and the sync log fits in one file. Litestream covers backups.", agentID: opusAgentID, streaming: false),
            .agentText(id: "ba2", text: "**Postgres.** Sync needs concurrent writers from many devices. Row-level locks and `LISTEN/NOTIFY` make the server side simpler.", agentID: gptAgentID, streaming: false),
            .board(id: "bb1", fromAgentID: grokAgentID, toAgentIDs: [opusAgentID, gptAgentID],
                   text: "Both of you assume one server. Clients keep SQLite either way; the question is only the server store.", date: ago(3700)),
            .agentText(id: "ba3", text: "Decision: SQLite on clients, Postgres on the server. The server needs concurrent writers; clients need zero setup.", agentID: grokAgentID, streaming: false),
        ]

        // MARK: Panels
        let mainContext = ContextBreakdown(usedTokens: 466_900, limitTokens: 1_000_000, categories: [
            .init(key: "messages", label: "Messages", tokens: 403_300),
            .init(key: "mcp", label: "MCP tools", tokens: 19_200),
            .init(key: "systemTools", label: "System tools", tokens: 17_500),
            .init(key: "systemPrompt", label: "System prompt", tokens: 12_200),
            .init(key: "skills", label: "Skills", tokens: 10_000),
            .init(key: "mcpInstructions", label: "MCP server instructions", tokens: 4_100),
            .init(key: "memory", label: "Memory files", tokens: 463),
            .init(key: "agents", label: "Custom agents", tokens: 357),
            .init(key: "buffer", label: "Autocompact buffer", tokens: 33_000),
            .init(key: "free", label: "Free space", tokens: 499_800),
        ])

        var contexts: [String: ContextBreakdown] = [mainSessionID: mainContext]
        for session in sessions where session.id != mainSessionID {
            contexts[session.id] = makeContext(messages: session.usage.inputTokens / 3, limit: session.model == gpt ? 400_000 : 1_000_000)
        }

        let mainChanges: [FileChange] = [
            FileChange(path: ensemble + "/Apps/Mac/ContextPanel/ContextBar.swift", kind: .added, additions: 19, diff: contextBarDiff),
            FileChange(path: ensemble + "/Apps/Mac/ContextPanel/ContextPanelView.swift", kind: .modified, additions: 142, deletions: 8),
            FileChange(path: ensemble + "/README.md", kind: .modified, additions: 6, deletions: 1),
            FileChange(path: ensemble + "/Packages/EnsembleKit/Sources/EnsembleKit/UI/Theme.swift", kind: .modified, additions: 24),
            FileChange(path: ensemble + "/project.yml", kind: .modified, additions: 2, deletions: 1),
            FileChange(path: ensemble + "/docs/PROGRESS.md", kind: .modified, additions: 1),
        ]

        let connectors: [ConnectorInfo] = [
            ConnectorInfo(id: "context7", name: "Context7", state: .connected, toolCount: 2),
            ConnectorInfo(id: "figma", name: "Figma", state: .failed),
            ConnectorInfo(id: "github", name: "GitHub", state: .connected, toolCount: 42),
            ConnectorInfo(id: "linear", name: "Linear", state: .needsAuth),
            ConnectorInfo(id: "notion", name: "Notion", state: .needsAuth),
            ConnectorInfo(id: "playwright", name: "Playwright", state: .connected, toolCount: 21),
            ConnectorInfo(id: "sentry", name: "Sentry", state: .needsAuth),
            ConnectorInfo(id: "slack", name: "Slack", state: .needsAuth),
        ]

        let models: [ModelInfo] = [
            ModelInfo(ref: opus, name: "Claude Opus 5.5", providerName: "Anthropic", contextLimit: 1_000_000, variants: ["high", "max"]),
            ModelInfo(ref: sonnet, name: "Claude Sonnet 5", providerName: "Anthropic", contextLimit: 1_000_000),
            ModelInfo(ref: ModelRef(providerID: "anthropic", id: "claude-haiku-5"), name: "Claude Haiku 5", providerName: "Anthropic", contextLimit: 200_000),
            ModelInfo(ref: gpt, name: "GPT-5.5", providerName: "OpenAI", contextLimit: 400_000, variants: ["low", "medium", "high"]),
            ModelInfo(ref: ModelRef(providerID: "openai", id: "gpt-5.5-mini"), name: "GPT-5.5 mini", providerName: "OpenAI", contextLimit: 400_000),
            ModelInfo(ref: grok, name: "Grok 5", providerName: "xAI", contextLimit: 256_000, available: false),
            ModelInfo(ref: ModelRef(providerID: "google", id: "gemini-3-pro"), name: "Gemini 3 Pro", providerName: "Google", contextLimit: 1_000_000, available: false),
            ModelInfo(ref: ModelRef(providerID: "openrouter", id: "deepseek/deepseek-v4"), name: "DeepSeek V4", providerName: "OpenRouter", contextLimit: 128_000, available: false),
        ]

        let providers: [ProviderInfo] = [
            ProviderInfo(id: "anthropic", name: "Anthropic", connected: true),
            ProviderInfo(id: "openai", name: "OpenAI", connected: true),
            ProviderInfo(id: "xai", name: "xAI", connected: false),
            ProviderInfo(id: "google", name: "Google", connected: false),
            ProviderInfo(id: "openrouter", name: "OpenRouter", connected: false),
            ProviderInfo(id: "custom", name: "Custom", connected: false),
        ]

        let agents = [
            AgentSpec(id: opusAgentID, name: "Opus", model: opus, role: "Argues for the simplest setup", colorHex: "#A78BFA"),
            AgentSpec(id: gptAgentID, name: "GPT", model: gpt, role: "Argues for scale", colorHex: "#34D399"),
            AgentSpec(id: grokAgentID, name: "Grok", model: grok, role: "Judge", colorHex: "#60A5FA"),
        ]

        return StoreSeed(
            sessions: sessions,
            transcripts: [
                mainSessionID: mainItems, childSessionID: childItems, "ses_sse_reconnect": sseItems,
                "ses_readme": readmeItems, "ses_dark_mode": darkModeItems, "ses_astro": astroItems,
                "ses_rate_limit": rateItems, "ses_db_debate": debateItems,
            ],
            activities: [mainSessionID: .waitingForPermission, "ses_sse_reconnect": .working,
                         "ses_dark_mode": .waitingForPermission, "ses_rate_limit": .failed],
            permissions: [testsPermission, darkModePermission],
            contexts: contexts,
            changes: [mainSessionID: mainChanges,
                      "ses_readme": [FileChange(path: ensemble + "/README.md", kind: .added, additions: 6)],
                      "ses_sse_reconnect": [FileChange(path: ensemble + "/Packages/EnsembleKit/Sources/EnsembleKit/OpenCode/EventStream.swift", kind: .modified, additions: 8, deletions: 1)]],
            modes: [mainSessionID: .ask, "ses_sse_reconnect": .acceptEdits, "ses_db_debate": .auto, "ses_rate_limit": .bypass],
            connectors: connectors,
            models: models,
            providers: providers,
            schedules: [
                ScheduleInfo(id: "sch_deps", title: "Nightly dependency check", prompt: "Check for outdated dependencies and open a summary.",
                             directory: ensemble, schedule: "0 3 * * *", nextRun: now.addingTimeInterval(3600 * 5)),
                ScheduleInfo(id: "sch_readme", title: "Weekly README refresh", prompt: "Update the README feature list from PROGRESS.md.",
                             directory: ensemble, schedule: "0 9 * * 1", paused: true),
            ],
            agents: agents,
            sessionAgentIDs: ["ses_db_debate": [opusAgentID, gptAgentID, grokAgentID]],
            extraFolders: [mainSessionID: [home + "/Developer/shared-kit"]],
            selectedSessionID: mainSessionID
        )
    }

    /// A plausible breakdown for a session with `messages` tokens of conversation.
    static func makeContext(messages: Int, limit: Int) -> ContextBreakdown {
        let fixed: [(String, String, Int)] = [
            ("mcp", "MCP tools", 19_200), ("systemTools", "System tools", 17_500),
            ("systemPrompt", "System prompt", 12_200), ("skills", "Skills", 10_000), ("memory", "Memory files", 463),
        ]
        let used = messages + fixed.reduce(0) { $0 + $1.2 }
        let buffer = min(33_000, limit / 30)
        var categories = [ContextBreakdown.Category(key: "messages", label: "Messages", tokens: messages)]
        categories += fixed.map { ContextBreakdown.Category(key: $0.0, label: $0.1, tokens: $0.2) }
        categories.append(.init(key: "buffer", label: "Autocompact buffer", tokens: buffer))
        categories.append(.init(key: "free", label: "Free space", tokens: max(0, limit - used - buffer)))
        return ContextBreakdown(usedTokens: used, limitTokens: limit, categories: categories)
    }
}
