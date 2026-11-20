import EnsembleKit
import SwiftUI

/// One session or room chat: transcript, floating composer card, permission mode, and room controls.
struct ChatView: View {
    let client: RemoteClient
    let sessionID: String
    let title: String

    @Environment(RemoteAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sending = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var confirmStop = false
    @State private var showMembers = false
    @State private var showModelPicker = false
    @State private var showDiffSheet = false
    @State private var showJumpToLatest = false
    @State private var copiedTranscript = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findScrollToken = 0
    @State private var roomFilter = RoomBoardFilter()
    @State private var pendingJumpItemID: String?
    @State private var sendHaptic = 0
    @State private var stopPauseHaptic = 0
    @State private var modelSwitchHaptic = 0
    /// Where the reader was when this view appeared (nil: the end).
    @State private var startAnchor: String??
    @FocusState private var composerFocused: Bool
    @FocusState private var findFocused: Bool

    private var transcript: RemoteTranscript? {
        client.openTranscript?.sessionID == sessionID ? client.openTranscript : nil
    }

    private var summary: SessionSummary? { client.sessions.first { $0.id == sessionID } }
    private var roomID: UUID? { transcript?.roomID ?? summary?.roomID }
    private var room: RemoteRoom? { client.room(id: roomID) }
    private var target: RemoteTarget { roomID.map { .room($0) } ?? .session(sessionID) }
    private var activity: SessionActivity { transcript?.activity ?? summary?.activity ?? .idle }
    private var currentMode: PermissionMode? { transcript?.permissionMode ?? room?.permissionMode }
    private var activeProviderID: String? { transcript?.modelProviderID ?? summary?.modelProviderID }
    private var activeModelID: String? { transcript?.modelID ?? summary?.modelID }
    private var activeModelName: String? { client.modelName(providerID: activeProviderID, modelID: activeModelID) }
    private var pendingModelName: String? { transcript?.pendingModelName ?? summary?.pendingModelName }
    private var sessionDirectory: String? { summary?.directory ?? room?.directory }
    private var sessionFolderName: String? { sessionDirectory.map(RemoteFormat.folderName) }
    private var hasHistory: Bool { !(transcript?.items.isEmpty ?? true) }
    private var agents: [UUID: RemoteAgent] {
        Dictionary((transcript?.agents ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var roomAgentsByID: [UUID: RemoteAgent] {
        var map = agents
        if let room {
            for agent in room.agents where map[agent.id] == nil {
                map[agent.id] = agent
            }
        }
        return map
    }
    private var visibleItems: [TranscriptItem] {
        guard let transcript else { return [] }
        if room != nil && roomFilter.isActive {
            return roomFilter.filter(transcript.items, agents: roomAgentsByID)
        }
        return transcript.items
    }
    private var findResult: TranscriptFindResult {
        showFind ? TranscriptFinder.search(findQuery, in: visibleItems) : .empty
    }
    private var findHighlight: TranscriptFindHighlight {
        showFind ? findResult.highlight(at: findIndex) : TranscriptFindHighlight()
    }
    private var activeFindItemID: String? {
        findResult.activeItemID(at: findIndex)
    }
    private var roomAgentCounts: [UUID: Int] {
        RoomBoardFilter.itemCountsByAgent(in: transcript?.items ?? [])
    }
    private var latestItemIDForSelectedAgent: String? {
        guard let agentID = roomFilter.agentID, let items = transcript?.items else { return nil }
        return RoomBoardFilter.latestItemID(for: agentID, in: items)
    }
    private var agentSpecs: [UUID: AgentSpec] {
        agents.mapValues { agent in
            AgentSpec(
                id: agent.id,
                name: agent.name,
                model: ModelRef(string: agent.model) ?? ModelRef(providerID: "remote", id: agent.model),
                colorHex: agent.colorHex
            )
        }
    }

    // Kept in RemoteAppModel so drafts, addressees, and scroll position survive Duo fold/unfold transitions.
    private var draft: Binding<String> {
        Binding(
            get: { model.drafts[sessionID] ?? "" },
            set: { model.drafts[sessionID] = $0.isEmpty ? nil : $0 }
        )
    }

    private var addressee: Binding<String?> {
        Binding(
            get: { model.addressees[sessionID] },
            set: { model.addressees[sessionID] = $0 }
        )
    }

    private var scrollAnchor: Binding<String?> {
        Binding(
            get: { model.scrollAnchors[sessionID] },
            set: { model.scrollAnchors[sessionID] = $0 }
        )
    }

    private static let bottomID = "bottom"
    private static let workingID = "working"
    private static let decisionID = "decision"

    private var decision: RemoteRoomDecision? { room.flatMap { client.openDecision(inRoom: $0.id) } }

    private var displayTitle: String {
        let candidate = transcript?.title ?? (title.isEmpty ? (summary?.title ?? "") : title)
        return candidate.isEmpty ? "Chat" : candidate
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if sizeClass != .regular, let goal = room?.goal {
                        RoomGoalStrip(goal: goal)
                    }
                    if let transcript {
                        if transcript.items.isEmpty && decision == nil && activity != .working {
                            EmptySessionView(
                                folderName: sessionFolderName,
                                modelName: room == nil ? (pendingModelName ?? activeModelName) : room?.mode.label,
                                permissionMode: currentMode
                            )
                        } else if room != nil && roomFilter.isActive && visibleItems.isEmpty {
                            RoomEmptyFilterView {
                                withAnimation(.snappy) { roomFilter.clear() }
                            }
                        } else {
                            let attribution = modelLabels(in: transcript.items)
                            let retryTarget = retryableError(in: transcript.items)
                            let highlight = findHighlight
                            ForEach(visibleItems) { item in
                                let isActiveMatch = highlight.activeItemID == item.id
                                let isMatch = highlight.matchedItemIDs.contains(item.id)
                                TranscriptRow(
                                    item: item,
                                    agents: agents,
                                    client: client,
                                    modelLabel: attribution[item.id],
                                    secondOpinions: transcript.secondOpinions,
                                    availableModels: room == nil ? client.availableModels : [],
                                    currentModelID: activeModelID,
                                    onRequestSecondOpinion: room == nil ? { itemID, replyText, option in
                                        act {
                                            try await client.requestSecondOpinion(
                                                sessionID: sessionID,
                                                itemID: itemID,
                                                replyText: replyText,
                                                providerID: option.providerID,
                                                modelID: option.modelID
                                            )
                                        }
                                    } : nil,
                                    retrySecondOpinion: room == nil ? { opinion, replyText in
                                        retryOpinionAction(for: opinion, replyText: replyText)
                                    } : nil,
                                    continueWithOpinionModel: room == nil ? { opinion in
                                        continueWithOpinionAction(for: opinion)
                                    } : nil,
                                    onRetryError: retryTarget?.errorID == item.id ? {
                                        if let text = retryTarget?.text { retrySend(text) }
                                    } : nil,
                                    onError: { actionError = $0 }
                                )
                                .padding(.horizontal, isMatch ? 8 : 0)
                                .padding(.vertical, isMatch ? 6 : 0)
                                .background(
                                    isActiveMatch
                                        ? RemoteTheme.accent.opacity(0.14)
                                        : (isMatch ? RemoteTheme.accent.opacity(0.06) : Color.clear),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            isActiveMatch
                                                ? RemoteTheme.accent
                                                : (isMatch ? RemoteTheme.accent.opacity(0.28) : Color.clear),
                                            lineWidth: isActiveMatch ? 1.5 : 1
                                        )
                                )
                                .id(item.id)
                            }
                        }
                        if let room, let decision {
                            RoomDecisionCard(
                                room: room,
                                decision: decision,
                                client: client,
                                onError: { actionError = $0 }
                            )
                            .id(Self.decisionID)
                        }
                        if activity == .working {
                            HStack(spacing: 8) {
                                ConstellationSpinner(size: 15)
                                Text("Working")
                                    .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                            }
                            .padding(.top, 2)
                            .id(Self.workingID)
                        }
                    } else if let loadError {
                        VStack(spacing: 12) {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                                .foregroundStyle(RemoteTheme.danger)
                                .multilineTextAlignment(.center)
                            Button("Try again") {
                                Task { await open() }
                            }
                            .buttonStyle(RemoteSecondaryButtonStyle())
                            .disabled(!client.state.isConnected)
                        }
                        .padding(.top, 48)
                        .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .scrollTargetLayout()
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: scrollAnchor, anchor: .bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 120
            } action: { _, away in
                withAnimation(.easeOut(duration: 0.16)) {
                    showJumpToLatest = away
                }
            }
            .refreshable {
                await open()
            }
            .remoteScreen()
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if showJumpToLatest && hasHistory {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                                .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                            Text("Jump to latest")
                                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                        }
                        .foregroundStyle(RemoteTheme.primaryText)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 36)
                        .background(RemoteTheme.cardRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                        .frame(minHeight: RemoteTheme.minTapTarget)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityLabel("Jump to latest")
                }
            }
            .onChange(of: transcript?.items.last) { old, _ in
                guard !showFind else { return }
                let anchor = model.scrollAnchors[sessionID]
                let atEnd = anchor == nil || anchor == Self.bottomID || anchor == Self.workingID
                    || anchor == Self.decisionID || anchor == old?.id
                if atEnd {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: transcript != nil) { _, loaded in
                if loaded { restoreScroll(proxy) }
            }
            .onChange(of: decision?.id) { _, id in
                if id != nil && !showFind {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = 0
                if showFind, let id = findResult.activeItemID(at: 0) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: activeFindItemID) { _, id in
                guard showFind, let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: findScrollToken) { _, _ in
                guard showFind, let id = activeFindItemID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: findResult.matchCount) { _, _ in
                let clamped = findResult.clampedIndex(findIndex)
                if clamped != findIndex {
                    findIndex = clamped
                }
            }
            .onChange(of: pendingJumpItemID) { _, targetID in
                guard let targetID else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                    pendingJumpItemID = nil
                }
            }
            .onChange(of: sessionID) { _, _ in
                closeFind()
                roomFilter.clear()
                pendingJumpItemID = nil
            }
            .onAppear {
                if startAnchor == nil { startAnchor = .some(model.scrollAnchors[sessionID]) }
                if transcript != nil { restoreScroll(proxy) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if room != nil || showFind {
                VStack(spacing: 0) {
                    if let room {
                        RoomAgentsBar(
                            room: room,
                            selectedAgentID: roomFilter.agentID,
                            agentCounts: roomAgentCounts,
                            onSelectAgent: { id in
                                withAnimation(.snappy) {
                                    roomFilter.agentID = id
                                }
                            },
                            onTapMembers: { showMembers = true }
                        )
                        if roomFilter.isActive {
                            RoomFilterStrip(
                                visibleCount: visibleItems.count,
                                totalCount: transcript?.items.count ?? 0,
                                selectedAgent: roomFilter.agentID.flatMap { roomAgentsByID[$0] },
                                category: roomFilter.category,
                                canJumpToLatest: latestItemIDForSelectedAgent != nil,
                                onJumpToLatest: jumpToSelectedAgentLatest,
                                onToggleHideNotices: {
                                    withAnimation(.snappy) {
                                        roomFilter.category = roomFilter.category == .hideNotices ? .all : .hideNotices
                                    }
                                },
                                onShowAll: {
                                    withAnimation(.snappy) {
                                        roomFilter.clear()
                                    }
                                }
                            )
                        }
                        if sizeClass == .regular, let goal = room.goal {
                            RoomGoalStrip(goal: goal)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(RemoteTheme.sidebar)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                                }
                        }
                    }
                    if showFind {
                        RemoteFindBar(
                            query: $findQuery,
                            focused: $findFocused,
                            statusText: findResult.statusText(at: findIndex),
                            hasMatches: !findResult.isEmpty,
                            onPrevious: { stepFind(forward: false) },
                            onNext: { stepFind(forward: true) },
                            onDone: closeFind
                        )
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RemoteComposerCard(
                draft: draft,
                addressee: addressee,
                focused: $composerFocused,
                room: room,
                mode: currentMode,
                modelName: activeModelName,
                pendingModelName: pendingModelName,
                canSwitchModel: room == nil && !client.availableModels.isEmpty,
                activity: activity,
                sending: sending,
                connected: client.state.isConnected,
                onSelectMode: { mode in
                    act { try await client.setPermissionMode(mode, for: target) }
                },
                onTapModel: {
                    showModelPicker = true
                },
                onClearPendingModel: (activeProviderID != nil && activeModelID != nil) ? {
                    guard let providerID = activeProviderID, let modelID = activeModelID else { return }
                    modelSwitchHaptic += 1
                    act {
                        try await client.changeModel(
                            sessionID: sessionID,
                            providerID: providerID,
                            modelID: modelID
                        )
                    }
                } : nil,
                onControlRoom: { action in
                    if action == .stop { confirmStop = true } else { control(action) }
                },
                onInterrupt: {
                    stopPauseHaptic += 1
                    act { try await client.interrupt(target) }
                },
                onSend: send
            )
        }
        .sheet(isPresented: $showMembers) {
            if let room {
                RoomMembersSheet(room: room)
                    .remoteThemeEnvironment()
            }
        }
        .sheet(isPresented: $showModelPicker) {
            RemoteModelPickerSheet(
                models: client.availableModels,
                currentProviderID: activeProviderID,
                currentModelID: activeModelID,
                pendingModelName: pendingModelName,
                hasHistory: hasHistory
            ) { option in
                modelSwitchHaptic += 1
                act {
                    try await client.changeModel(
                        sessionID: sessionID,
                        providerID: option.providerID,
                        modelID: option.modelID
                    )
                }
            }
            .remoteThemeEnvironment()
        }
        .sheet(isPresented: $showDiffSheet) {
            RemoteDiffSheet(client: client, sessionID: sessionID, title: displayTitle)
                .remoteThemeEnvironment()
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: "\(sessionID)-\(client.state.isConnected)") { await open() }
        .actionErrorAlert($actionError)
        .sensoryFeedback(.impact(weight: .light), trigger: sendHaptic)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopPauseHaptic)
        .sensoryFeedback(.selection, trigger: modelSwitchHaptic)
        .confirmationDialog("Stop \(room?.title ?? "the room")?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop the room", role: .destructive) { control(.stop) }
        } message: {
            Text("Ends the run. The sessions and the board stay, and a new message starts another run.")
        }
    }

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        let anchorTarget = (startAnchor ?? nil) ?? Self.bottomID
        DispatchQueue.main.async { proxy.scrollTo(anchorTarget, anchor: .bottom) }
    }

    private func open() async {
        guard client.state.isConnected else { return }
        do {
            loadError = nil
            try await client.open(sessionID: sessionID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(displayTitle)
                .font(RemoteTheme.font(size: 16, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.primaryText)
                .lineLimit(1)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showDiffSheet = true
            } label: {
                Image(systemName: "plus.forwardslash.minus")
                    .font(RemoteTheme.font(size: 14, weight: .medium, relativeTo: .body))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .frame(minWidth: 36, minHeight: 36)
            }
            .disabled(!client.state.isConnected)
            .accessibilityLabel("Changes")

            Menu {
                if hasHistory {
                    Button {
                        withAnimation(.snappy) {
                            showFind = true
                        }
                        findFocused = true
                    } label: {
                        Label("Find in chat", systemImage: "magnifyingglass")
                    }
                }
                if room != nil && hasHistory {
                    Button {
                        withAnimation(.snappy) {
                            roomFilter.category = roomFilter.category == .hideNotices ? .all : .hideNotices
                        }
                    } label: {
                        Label(
                            roomFilter.category == .hideNotices ? "Show notices" : "Hide notices",
                            systemImage: roomFilter.category == .hideNotices ? "eye" : "eye.slash"
                        )
                    }
                }
                if let room, !room.members.isEmpty || !room.agents.isEmpty {
                    Button {
                        showMembers = true
                    } label: {
                        Label("Members", systemImage: "person.2")
                    }
                }
                if let transcript, !transcript.items.isEmpty {
                    Button {
                        copyTranscriptMarkdown(transcript)
                    } label: {
                        Label(
                            copiedTranscript ? "Copied Markdown" : "Copy as Markdown",
                            systemImage: copiedTranscript ? "checkmark" : "doc.on.doc"
                        )
                    }
                    ShareLink(
                        item: exportedMarkdown(for: transcript),
                        subject: Text(displayTitle)
                    ) {
                        Label("Share transcript", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    Task { await open() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!client.state.isConnected)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .body))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .frame(minWidth: 36, minHeight: 36)
            }
            .accessibilityLabel("More actions")
        }
    }

    private func stepFind(forward: Bool) {
        guard !findResult.isEmpty else { return }
        findIndex = forward ? findResult.nextIndex(after: findIndex) : findResult.previousIndex(before: findIndex)
        findScrollToken += 1
    }

    private func closeFind() {
        withAnimation(.snappy) {
            showFind = false
        }
        findQuery = ""
        findIndex = 0
        findFocused = false
    }

    private func jumpToSelectedAgentLatest() {
        guard let targetID = latestItemIDForSelectedAgent else { return }
        withAnimation(.snappy) {
            roomFilter.clear()
        }
        pendingJumpItemID = targetID
    }

    private func exportedMarkdown(for transcript: RemoteTranscript) -> String {
        TranscriptExport.markdown(
            title: displayTitle,
            directory: sessionDirectory,
            modelName: activeModelName,
            items: transcript.items,
            agents: agentSpecs
        )
    }

    private func copyTranscriptMarkdown(_ transcript: RemoteTranscript) {
        copyToPasteboard(exportedMarkdown(for: transcript))
        modelSwitchHaptic += 1
        copiedTranscript = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedTranscript = false
        }
    }

    private func modelLabels(in items: [TranscriptItem]) -> [String: String] {
        var result: [String: String] = [:]
        var pendingModel: String?
        for item in items {
            switch item {
            case .notice(_, let text):
                if let switched = TranscriptExport.switchedModelName(fromNotice: text) {
                    pendingModel = switched
                }
            case .agentText(let id, _, let agentID, _):
                if agentID == nil, let model = pendingModel {
                    result[id] = model
                }
                pendingModel = nil
            default:
                break
            }
        }
        return result
    }

    private func retryableError(in items: [TranscriptItem]) -> (errorID: String, text: String)? {
        guard client.state.isConnected, !sending, activity != .working else { return nil }
        var latestErrorIndex: Int?
        for i in items.indices.reversed() {
            switch items[i] {
            case .error:
                latestErrorIndex = i
            case .user, .agentText:
                return nil
            default:
                continue
            }
            if latestErrorIndex != nil { break }
        }
        guard let errorIndex = latestErrorIndex else { return nil }
        for item in items[..<errorIndex].reversed() {
            if case .user(_, let text, _) = item {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (items[errorIndex].id, trimmed)
                }
            }
        }
        return nil
    }

    private func matchingModelOption(for opinion: RemoteSecondOpinion) -> RemoteModelOption? {
        if let exact = client.availableModels.first(where: {
            $0.name.caseInsensitiveCompare(opinion.modelName) == .orderedSame
                && (opinion.makerName.isEmpty || $0.makerName.caseInsensitiveCompare(opinion.makerName) == .orderedSame)
        }) {
            return exact
        }
        if let byName = client.availableModels.first(where: {
            $0.name.caseInsensitiveCompare(opinion.modelName) == .orderedSame
        }) {
            return byName
        }
        return client.availableModels.first(where: {
            $0.modelID.caseInsensitiveCompare(opinion.modelName) == .orderedSame
                || $0.name.localizedCaseInsensitiveContains(opinion.modelName)
        })
    }

    private func retryOpinionAction(for opinion: RemoteSecondOpinion, replyText: String) -> (() -> Void)? {
        guard opinion.status == "failed",
              client.state.isConnected,
              let option = matchingModelOption(for: opinion) else { return nil }
        return {
            act {
                try await client.requestSecondOpinion(
                    sessionID: sessionID,
                    itemID: opinion.itemID,
                    replyText: replyText,
                    providerID: option.providerID,
                    modelID: option.modelID
                )
            }
        }
    }

    private func continueWithOpinionAction(for opinion: RemoteSecondOpinion) -> (() -> Void)? {
        guard opinion.status == "ready",
              client.state.isConnected,
              let option = matchingModelOption(for: opinion) else { return nil }
        if option.providerID == activeProviderID && option.modelID == activeModelID && pendingModelName == nil {
            return nil
        }
        return {
            modelSwitchHaptic += 1
            act {
                try await client.changeModel(
                    sessionID: sessionID,
                    providerID: option.providerID,
                    modelID: option.modelID
                )
            }
        }
    }

    private func control(_ action: RemoteRoomAction) {
        guard let id = roomID else { return }
        if action == .pause || action == .stop { stopPauseHaptic += 1 }
        act { try await client.controlRoom(id, action: action) }
    }

    private func send() {
        let text = (model.drafts[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendHaptic += 1
        sending = true
        let to = target
        let agent = model.addressees[sessionID]
        Task {
            do {
                try await client.send(text, to: to, agent: agent)
                model.drafts[sessionID] = nil
            } catch {
                actionError = error.localizedDescription
            }
            sending = false
        }
    }

    private func retrySend(_ text: String) {
        guard !text.isEmpty else { return }
        sendHaptic += 1
        sending = true
        let to = target
        let agent = model.addressees[sessionID]
        Task {
            do {
                try await client.send(text, to: to, agent: agent)
            } catch {
                actionError = error.localizedDescription
            }
            sending = false
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }
}

// MARK: - Empty Session View

private struct EmptySessionView: View {
    let folderName: String?
    let modelName: String?
    let permissionMode: PermissionMode?

    var body: some View {
        VStack(spacing: 12) {
            ConstellationSpinner(size: 36, frozenAt: 1.1)
            if let folderName, !folderName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)
                    Text(folderName)
                        .font(RemoteTheme.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if modelName != nil || permissionMode != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        metadataChips
                    }
                    VStack(spacing: 8) {
                        metadataChips
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var metadataChips: some View {
        if let modelName, !modelName.isEmpty {
            Chip(text: modelName, color: RemoteTheme.accent, symbol: "cpu")
        }
        if let permissionMode {
            Chip(
                text: permissionMode.label,
                color: permissionMode.isDangerous ? RemoteTheme.danger : RemoteTheme.secondaryText,
                symbol: permissionMode.symbolName
            )
        }
    }
}

// MARK: - Floating Composer Card

private struct RemoteComposerCard: View {
    @Binding var draft: String
    @Binding var addressee: String?
    var focused: FocusState<Bool>.Binding
    let room: RemoteRoom?
    let mode: PermissionMode?
    let modelName: String?
    let pendingModelName: String?
    let canSwitchModel: Bool
    let activity: SessionActivity
    let sending: Bool
    let connected: Bool
    let onSelectMode: (PermissionMode) -> Void
    let onTapModel: () -> Void
    let onClearPendingModel: (() -> Void)?
    let onControlRoom: (RemoteRoomAction) -> Void
    let onInterrupt: () -> Void
    let onSend: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var trimmedEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        if let addressee { return "Message @\(addressee)..." }
        return "Message..."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let room, !room.agents.isEmpty {
                    AddresseeChipStrip(agents: room.agents, selected: $addressee)
                }

                if room == nil, let pendingModelName {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(RemoteTheme.font(size: 10.5, weight: .semibold, relativeTo: .caption2))
                            .foregroundStyle(RemoteTheme.accent)
                        Text("Next message: \(pendingModelName)")
                            .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let onClearPendingModel {
                            Button(action: onClearPendingModel) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(RemoteTheme.font(size: 14, relativeTo: .caption))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!connected)
                            .accessibilityLabel("Cancel model switch")
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, onClearPendingModel == nil ? 10 : 4)
                    .padding(.vertical, onClearPendingModel == nil ? 5 : 2)
                    .background(RemoteTheme.accent.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(RemoteTheme.accent.opacity(0.32), lineWidth: 0.75))
                }

                TextField(placeholder, text: $draft, axis: .vertical)
                    .font(RemoteTheme.font(size: 15, relativeTo: .body))
                    .lineLimit(1...6)
                    .focused(focused)
                    .foregroundStyle(RemoteTheme.primaryText)
                    .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if let room {
                                modeBadge(room.permissionMode)
                                if room.state == .paused {
                                    roomActionPill("Resume", systemImage: "play.fill", tint: RemoteTheme.accent) {
                                        onControlRoom(.resume)
                                    }
                                } else if room.state == .running {
                                    roomActionPill("Pause", systemImage: "pause.fill", tint: RemoteTheme.secondaryText) {
                                        onControlRoom(.pause)
                                    }
                                }
                                if room.isRunActive {
                                    roomActionPill("Stop", systemImage: "stop.fill", tint: RemoteTheme.danger) {
                                        onControlRoom(.stop)
                                    }
                                }
                            } else {
                                if let mode {
                                    PermissionModeMenuCapsule(current: mode, onSelect: onSelectMode)
                                }
                                if canSwitchModel {
                                    modelPickerCapsule
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    actionCircleButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(
                RemoteTheme.card,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        focused.wrappedValue ? RemoteTheme.accent.opacity(0.6) : RemoteTheme.border,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.34 : 0.08),
                radius: 12,
                y: 4
            )
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: RemoteTheme.background.opacity(0), location: 0),
                    .init(color: RemoteTheme.background, location: 0.14),
                    .init(color: RemoteTheme.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private var actionCircleButton: some View {
        if activity == .working && trimmedEmpty {
            Button(action: onInterrupt) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(RemoteTheme.background)
                    .frame(width: 12, height: 12)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(RemoteTheme.primaryText))
                    .frame(minWidth: RemoteTheme.minTapTarget, minHeight: RemoteTheme.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(room == nil ? "Stop" : "Pause")
        } else {
            let canSend = !trimmedEmpty && !sending && connected
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(RemoteTheme.font(size: 15, weight: .bold, relativeTo: .body))
                    .foregroundStyle(canSend ? RemoteTheme.onAccent : RemoteTheme.tertiaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(canSend ? RemoteTheme.accent : RemoteTheme.track))
                    .frame(minWidth: RemoteTheme.minTapTarget, minHeight: RemoteTheme.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private var modelPickerCapsule: some View {
        Button(action: onTapModel) {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(RemoteTheme.font(size: 11, weight: .medium, relativeTo: .caption))
                Text(pendingModelName ?? modelName ?? "Model")
                    .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(RemoteTheme.font(size: 9.5, weight: .semibold, relativeTo: .caption2))
            }
            .foregroundStyle(pendingModelName != nil ? RemoteTheme.accent : RemoteTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RemoteTheme.cardRaised, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        pendingModelName != nil ? RemoteTheme.accent.opacity(0.45) : RemoteTheme.border,
                        lineWidth: 0.75
                    )
            )
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!connected)
        .accessibilityLabel("Switch model")
    }

    private func modeBadge(_ mode: PermissionMode) -> some View {
        HStack(spacing: 5) {
            Image(systemName: mode.symbolName)
                .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption))
            Text(mode.shortLabel)
                .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(mode.isDangerous ? RemoteTheme.danger : RemoteTheme.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(RemoteTheme.cardRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
        .accessibilityLabel("Permission mode: \(mode.label)")
    }

    private func roomActionPill(
        _ label: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(RemoteTheme.font(size: 11, weight: .semibold, relativeTo: .caption2))
                Text(label)
                    .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.75))
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AddresseeChipStrip: View {
    let agents: [RemoteAgent]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "@all", color: RemoteTheme.accent, isSelected: selected == nil) {
                    selected = nil
                }
                ForEach(agents) { agent in
                    let agentColor = Color(remoteHex: agent.colorHex)
                    chip(label: "@\(agent.name)", color: agentColor, isSelected: selected == agent.name) {
                        selected = selected == agent.name ? nil : agent.name
                    }
                }
            }
        }
    }

    private func chip(label: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isSelected ? color : color.opacity(0.65))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(RemoteTheme.font(size: 12.5, weight: isSelected ? .semibold : .medium, relativeTo: .caption))
                    .foregroundStyle(isSelected ? RemoteTheme.primaryText : RemoteTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (isSelected ? color.opacity(0.16) : RemoteTheme.cardRaised),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? color.opacity(0.6) : RemoteTheme.border, lineWidth: 0.75)
            )
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionModeMenuCapsule: View {
    let current: PermissionMode
    let onSelect: (PermissionMode) -> Void

    var body: some View {
        Menu {
            Section("Permission mode") {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        if mode == current {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Label(mode.label, systemImage: mode.symbolName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.symbolName)
                    .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption))
                Text(current.shortLabel)
                    .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(RemoteTheme.font(size: 9.5, weight: .semibold, relativeTo: .caption2))
            }
            .fixedSize()
            .foregroundStyle(current.isDangerous ? RemoteTheme.danger : RemoteTheme.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RemoteTheme.cardRaised, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        current.isDangerous ? RemoteTheme.danger.opacity(0.45) : RemoteTheme.border,
                        lineWidth: 0.75
                    )
            )
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Permission mode: \(current.label)")
    }
}

private struct RoomMembersSheet: View {
    let room: RemoteRoom
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let goal = room.goal {
                        RoomGoalStrip(goal: goal)
                    }
                    if !room.members.isEmpty {
                        RoomMembersList(room: room)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(room.agents) { agent in
                                HStack(spacing: 8) {
                                    AgentTag(agent: agent, showModel: true)
                                    if agent.id == room.leadAgentID { Chip(text: "Lead") }
                                    Spacer()
                                    AgentActivityIcon(agent: agent)
                                    Text(RoomText.activity(agent))
                                        .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                                        .foregroundStyle(RemoteTheme.secondaryText)
                                }
                                .remoteCard(padding: 12)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .remoteScreen()
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Live Find Bar & Room Board Filter Strip

private struct RemoteFindBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let statusText: String
    let hasMatches: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.tertiaryText)
                    TextField("Find in transcript", text: $query)
                        .font(RemoteTheme.font(size: 14.5, relativeTo: .body))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .focused(focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(onNext)
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption2).monospacedDigit())
                            .foregroundStyle(hasMatches ? RemoteTheme.secondaryText : RemoteTheme.danger)
                            .fixedSize()
                    }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(RemoteTheme.font(size: 14, relativeTo: .footnote))
                                .foregroundStyle(RemoteTheme.tertiaryText)
                                .frame(minWidth: 28, minHeight: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear find query")
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, query.isEmpty ? 10 : 4)
                .frame(minHeight: 38)
                .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            focused.wrappedValue ? RemoteTheme.accent.opacity(0.6) : RemoteTheme.border,
                            lineWidth: 1
                        )
                )

                navButton(systemImage: "chevron.up", label: "Previous match", action: onPrevious)
                navButton(systemImage: "chevron.down", label: "Next match", action: onNext)

                Button(action: onDone) {
                    Text("Done")
                        .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(RemoteTheme.accent)
                        .padding(.horizontal, 6)
                        .frame(minHeight: RemoteTheme.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Close find")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RemoteTheme.sidebar)

            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
        }
    }

    private func navButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(RemoteTheme.font(size: 13, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(hasMatches ? RemoteTheme.primaryText : RemoteTheme.tertiaryText.opacity(0.5))
                .frame(width: 36, height: 36)
                .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                )
                .frame(minWidth: 38, minHeight: RemoteTheme.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasMatches)
        .accessibilityLabel(label)
    }
}

private struct RoomFilterStrip: View {
    let visibleCount: Int
    let totalCount: Int
    let selectedAgent: RemoteAgent?
    let category: RoomBoardCategory
    let canJumpToLatest: Bool
    let onJumpToLatest: () -> Void
    let onToggleHideNotices: () -> Void
    let onShowAll: () -> Void

    private var hidingNotices: Bool { category == .hideNotices }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let selectedAgent {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(remoteHex: selectedAgent.colorHex))
                                .frame(width: 7, height: 7)
                            Text("\(selectedAgent.name) \u{00B7} \(visibleCount) of \(totalCount)")
                                .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption).monospacedDigit())
                                .foregroundStyle(RemoteTheme.secondaryText)
                                .fixedSize()
                        }
                    } else {
                        Text("Showing \(visibleCount) of \(totalCount)")
                            .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .fixedSize()
                    }

                    if canJumpToLatest {
                        Button(action: onJumpToLatest) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(RemoteTheme.font(size: 10.5, weight: .semibold, relativeTo: .caption2))
                                Text("Jump to latest")
                                    .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                            }
                            .foregroundStyle(RemoteTheme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(RemoteTheme.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(RemoteTheme.accent.opacity(0.32), lineWidth: 0.75))
                            .frame(minHeight: RemoteTheme.minTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onToggleHideNotices) {
                        HStack(spacing: 4) {
                            Image(systemName: hidingNotices ? "eye.slash.fill" : "line.3.horizontal.decrease.circle")
                                .font(RemoteTheme.font(size: 10.5, weight: .semibold, relativeTo: .caption2))
                            Text(hidingNotices ? RoomBoardCategory.hideNotices.label : RoomBoardCategory.all.label)
                                .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                        }
                        .foregroundStyle(hidingNotices ? RemoteTheme.accent : RemoteTheme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(hidingNotices ? RemoteTheme.accent.opacity(0.12) : RemoteTheme.card, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                hidingNotices ? RemoteTheme.accent.opacity(0.35) : RemoteTheme.border,
                                lineWidth: 0.75
                            )
                        )
                        .frame(minHeight: RemoteTheme.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hidingNotices ? "Hiding notices" : "Showing all categories")
                    .accessibilityHint("Toggle hiding notices")

                    Button(action: onShowAll) {
                        Text("Show all")
                            .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.primaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(RemoteTheme.cardRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
                            .frame(minHeight: RemoteTheme.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .background(RemoteTheme.sidebar)
            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
        }
    }
}

private struct RoomEmptyFilterView: View {
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(RemoteTheme.tertiaryText)
            Text("No matching messages")
                .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.secondaryText)
            Button("Show all", action: onShowAll)
                .buttonStyle(RemoteSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 24)
    }
}
