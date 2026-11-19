import EnsembleKit
import SwiftUI

/// Standalone Session Hub screen for compact width (outer Duo screen).
struct HubView: View {
    let client: RemoteClient
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void

    @State private var showNewSession = false

    var body: some View {
        HubBoardContent(client: client, selectedSessionID: selectedSessionID, open: open)
            .navigationTitle("Session Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNewSession = true
                    } label: {
                        Image(systemName: "plus")
                            .font(RemoteTheme.font(size: 15, weight: .semibold, relativeTo: .body))
                            .foregroundStyle(RemoteTheme.accent)
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .disabled(!client.state.isConnected || client.availableModels.isEmpty)
                    .accessibilityLabel("New session")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(client: client, inToolbar: true)
                }
            }
            .sheet(isPresented: $showNewSession) {
                RemoteNewSessionSheet(client: client) { created in
                    open(ChatRoute(sessionID: created.id, title: created.title))
                }
                .remoteThemeEnvironment()
            }
    }
}

/// Reusable Session Hub board used in both the compact tab and the unfolded split sidebar.
struct HubBoardContent: View {
    let client: RemoteClient
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void

    @State private var showOld = false
    @State private var actionError: String?

    private var groups: [HubBucket: [SessionSummary]] { HubBoard.group(client.sessions) }
    private var visibleBuckets: [HubBucket] {
        let grouped = groups
        return [HubBucket.needsYou, .running, .finished].filter { !(grouped[$0] ?? []).isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RemoteTheme.sectionGap) {
                if !client.isInProcess && !client.state.isConnected {
                    HubConnectionBanner(client: client)
                }

                if client.sessions.isEmpty {
                    HubEmptyState(client: client)
                }

                ForEach(visibleBuckets, id: \.self) { bucket in
                    let rows = groups[bucket] ?? []
                    HubSectionBlock(
                        bucket: bucket,
                        rows: rows,
                        client: client,
                        selectedSessionID: selectedSessionID,
                        open: open,
                        onAct: runAction,
                        onError: { actionError = $0 }
                    )
                }

                if let old = groups[.old], !old.isEmpty {
                    HubOldSection(
                        rows: old,
                        expanded: $showOld,
                        client: client,
                        selectedSessionID: selectedSessionID,
                        open: open,
                        onAct: runAction,
                        onError: { actionError = $0 }
                    )
                }
            }
            .padding(.horizontal, RemoteTheme.screenHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .remoteScreen()
        .refreshable {
            if !client.state.isConnected && !client.isInProcess {
                client.reconnectNow()
            }
            try? await client.refreshHub()
        }
        .actionErrorAlert($actionError)
    }

    private func runAction(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }
}

// MARK: - Connection banner & empty state

struct HubConnectionBanner: View {
    let client: RemoteClient

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(RemoteTheme.font(size: 16, weight: .semibold, relativeTo: .body))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(client.state.statusText)
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Reconnect") { client.reconnectNow() }
                .buttonStyle(RemoteSecondaryButtonStyle(minHeight: 38))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private var tint: Color {
        switch client.state {
        case .macOffline, .connecting, .waiting: RemoteTheme.warning
        case .idle, .rejected, .limitReached: RemoteTheme.danger
        case .connected: RemoteTheme.success
        }
    }

    private var icon: String {
        switch client.state {
        case .macOffline: "desktopcomputer.trianglebadge.exclamationmark"
        case .rejected, .limitReached: "exclamationmark.triangle.fill"
        default: "wifi.exclamationmark"
        }
    }
}

private struct HubEmptyState: View {
    let client: RemoteClient

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(RemoteTheme.tertiaryText)
            Text(emptyText)
                .font(RemoteTheme.font(size: 16, weight: .medium, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    private var emptyText: String {
        switch client.state {
        case .connected: "No sessions yet"
        case .macOffline, .limitReached, .rejected: client.state.statusText
        case .idle, .connecting, .waiting: "Waiting for your Mac"
        }
    }
}

// MARK: - Sections & Cards

private struct HubSectionBlock: View {
    let bucket: HubBucket
    let rows: [SessionSummary]
    let client: RemoteClient
    let selectedSessionID: String?
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RemoteTheme.cardGap) {
            HubSectionHeader(bucket: bucket, count: rows.count)
            ForEach(rows) { session in
                HubSessionCard(
                    session: session,
                    bucket: bucket,
                    client: client,
                    selected: session.id == selectedSessionID,
                    open: open,
                    onAct: onAct,
                    onError: onError
                )
            }
        }
    }
}

private struct HubOldSection: View {
    let rows: [SessionSummary]
    @Binding var expanded: Bool
    let client: RemoteClient
    let selectedSessionID: String?
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RemoteTheme.cardGap) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(expanded ? "Hide older" : "Older")
                        .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                    Text("\(rows.count)")
                        .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RemoteTheme.cardRaised, in: Capsule())
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                }
                .foregroundStyle(RemoteTheme.secondaryText)
                .padding(.horizontal, 4)
                .frame(minHeight: RemoteTheme.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(rows) { session in
                    HubSessionCard(
                        session: session,
                        bucket: .old,
                        client: client,
                        selected: session.id == selectedSessionID,
                        open: open,
                        onAct: onAct,
                        onError: onError
                    )
                }
            }
        }
    }
}

private struct HubSectionHeader: View {
    let bucket: HubBucket
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            marker
            Text(bucket.label)
                .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(bucket == .needsYou ? RemoteTheme.primaryText : RemoteTheme.secondaryText)
            Text("\(count)")
                .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(bucket == .needsYou ? RemoteTheme.warning : RemoteTheme.tertiaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (bucket == .needsYou ? RemoteTheme.warning.opacity(0.16) : RemoteTheme.cardRaised),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var marker: some View {
        switch bucket {
        case .needsYou:
            RemoteLiveDot(color: RemoteTheme.warning, size: 7)
        case .running:
            RemoteLiveDot(color: RemoteTheme.success, size: 7, pulsing: true)
        case .finished:
            Circle().fill(RemoteTheme.tertiaryText.opacity(0.5)).frame(width: 7, height: 7)
        case .old:
            Circle().fill(RemoteTheme.tertiaryText.opacity(0.35)).frame(width: 7, height: 7)
        }
    }
}

private struct HubSessionCard: View {
    let session: SessionSummary
    let bucket: HubBucket
    let client: RemoteClient
    let selected: Bool
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    let onError: (String) -> Void

    var body: some View {
        let hasInlineAction = (session.roomID.flatMap { client.room(id: $0) } != nil)
            || !client.pendingPermissions(for: session.id).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            Button {
                open(ChatRoute(sessionID: session.id, title: session.title))
            } label: {
                HubRowHeader(session: session, bucket: bucket, showsInlineAction: hasInlineAction)
            }
            .buttonStyle(.plain)

            HubQuickActions(
                session: session,
                bucket: bucket,
                client: client,
                open: open,
                onAct: onAct,
                onError: onError
            )
        }
        .remoteCard(selected: selected, attention: bucket == .needsYou)
    }
}

struct HubRowHeader: View {
    let session: SessionSummary
    let bucket: HubBucket
    var showsInlineAction = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(RemoteTheme.font(size: 15.5, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text(RemoteFormat.age(session.lastActivity))
                        .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: session.roomID != nil ? "person.2.fill" : "folder")
                            .font(RemoteTheme.font(size: 10.5, weight: .medium, relativeTo: .caption2))
                        Text(RemoteFormat.folderName(session.directory))
                    }
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(RemoteTheme.inlineCodeBackground, in: Capsule())

                    if !session.agentNames.isEmpty {
                        Text(session.agentNames.joined(separator: ", "))
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .lineLimit(1)
                    }

                    if session.usage.costUSD > 0 {
                        Spacer(minLength: 4)
                        Text(RemoteFormat.cost(session.usage.costUSD))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(RemoteTheme.font(size: 12, relativeTo: .caption))

                if let ask = session.pendingAsk, bucket == .needsYou, !showsInlineAction {
                    Text(ask)
                        .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.warning)
                        .lineLimit(2)
                }
            }

            Image(systemName: "chevron.right")
                .font(RemoteTheme.font(size: 11.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.tertiaryText)
                .padding(.top, 5)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        switch bucket {
        case .needsYou:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(RemoteTheme.warning)
        case .running:
            ConstellationSpinner(size: 16)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(RemoteTheme.success)
        case .old:
            Image(systemName: "clock")
                .font(.system(size: 15))
                .foregroundStyle(RemoteTheme.tertiaryText)
        }
    }
}

// MARK: - Quick actions

private struct HubQuickActions: View {
    let session: SessionSummary
    let bucket: HubBucket
    let client: RemoteClient
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    let onError: (String) -> Void

    var body: some View {
        if let roomID = session.roomID, let room = client.room(id: roomID) {
            HubRoomQuickActions(room: room, client: client, open: open, onAct: onAct, onError: onError)
        } else if let ask = client.pendingPermissions(for: session.id).first, ask.isInteraction {
            HubInteractionQuickActions(ask: ask, session: session, client: client, open: open, onAct: onAct)
        } else if let ask = client.pendingPermissions(for: session.id).first, PermissionDisplay.fitsQuickApproval(ask) {
            VStack(alignment: .leading, spacing: 10) {
                // Never truncated: everything a one-tap approval covers is on screen.
                RemoteCommandBox(text: ask.title)
                HStack(spacing: 10) {
                    Button("Allow once") {
                        onAct { try await client.reply(to: ask, decision: .once) }
                    }
                    .buttonStyle(RemotePrimaryButtonStyle())

                    Button("Reject", role: .destructive) {
                        onAct { try await client.reply(to: ask, decision: .reject) }
                    }
                    .buttonStyle(
                        RemoteSecondaryButtonStyle(
                            foreground: RemoteTheme.danger,
                            border: RemoteTheme.danger.opacity(0.4)
                        )
                    )
                }
            }
        } else if bucket == .running {
            let target: RemoteTarget = session.roomID.map { .room($0) } ?? .session(session.id)
            Button {
                onAct { try await client.interrupt(target) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(RemoteSecondaryButtonStyle())
        }
    }
}

private struct HubRoomQuickActions: View {
    let room: RemoteRoom
    let client: RemoteClient
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    let onError: (String) -> Void

    var body: some View {
        let route = ChatRoute(sessionID: room.sessionID, title: room.title)
        if let decision = client.openDecision(inRoom: room.id), decision.needsYou {
            Button(RoomText.openLabel(decision)) { open(route) }
                .buttonStyle(RemotePrimaryButtonStyle())
        } else if let request = client.pendingPermissions(inRoom: room.id).first {
            RoomPromptRow(
                request: request,
                agent: room.agents.first { $0.sessionID == request.sessionID },
                client: client,
                open: { open(route) },
                onError: onError
            )
        } else if room.state == .running {
            Button {
                onAct { try await client.controlRoom(room.id, action: .pause) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(RemoteSecondaryButtonStyle())
        }
    }
}

private struct HubInteractionQuickActions: View {
    let ask: PermissionRequest
    let session: SessionSummary
    let client: RemoteClient
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void

    var body: some View {
        if let plan = ask.plan {
            VStack(alignment: .leading, spacing: 10) {
                Text(plan.title)
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .lineLimit(3)
                PlanButtons(plan: plan) { decision in
                    onAct { try await client.respond(to: ask, decision: decision) }
                }
            }
        } else if let questions = ask.questions, questions.count == 1, let question = questions.first,
                  !question.multiSelect, !question.options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(question.text)
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                FlowButtons(labels: question.options.map(\.label)) { label in
                    onAct {
                        try await client.answer(ask, answers: [AgentQuestionAnswer(questionID: question.id, selected: [label])])
                    }
                }
                if question.allowsOther {
                    Button("Type an answer") { open(ChatRoute(sessionID: session.id, title: session.title)) }
                        .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)
                        .frame(minHeight: 36)
                }
            }
        } else {
            Button {
                open(ChatRoute(sessionID: session.id, title: session.title))
            } label: {
                Label("Answer", systemImage: "questionmark.bubble")
            }
            .buttonStyle(RemotePrimaryButtonStyle())
        }
    }
}

/// Small bordered buttons that wrap cleanly using FlowRow so labels never truncate.
struct FlowButtons: View {
    let labels: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(labels, id: \.self) { label in
                Button(label) { onTap(label) }
                    .buttonStyle(RemoteSecondaryButtonStyle(minHeight: 40))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
