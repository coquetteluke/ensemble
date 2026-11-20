import EnsembleKit
import SwiftUI

/// Standalone Session Hub screen for compact width (outer Duo screen).
struct HubView: View {
    let client: RemoteClient
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void

    @State private var showNewSession = false

    private var newSessionAccessibilityHint: String {
        if !client.state.isConnected { return "Connect to your Mac to start a session" }
        if client.availableModels.isEmpty { return "Loading available models from your Mac" }
        return "Start a new session"
    }

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
                    .accessibilityHint(newSessionAccessibilityHint)
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
    @State private var filter = HubFilter()
    @State private var confirmArchiveFinished = false
    @State private var archivingFinished = false
    @State private var pendingArchiveIDs: [String] = []

    private var projects: [HubProjectOption] { HubFilter.projects(from: client.sessions) }
    private var filteredSessions: [SessionSummary] { filter.filter(client.sessions) }
    private var groups: [HubBucket: [SessionSummary]] { HubBoard.group(filteredSessions) }
    private var visibleBuckets: [HubBucket] {
        let grouped = groups
        return [HubBucket.needsYou, .running, .finished].filter { !(grouped[$0] ?? []).isEmpty }
    }
    private var showFilterBar: Bool { client.sessions.count >= 3 || filter.isActive }
    private var hasNoMatches: Bool {
        filter.isActive && !client.sessions.isEmpty && visibleBuckets.isEmpty && (groups[.old]?.isEmpty ?? true)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RemoteTheme.sectionGap) {
                if !client.isInProcess && !client.state.isConnected {
                    HubConnectionBanner(client: client)
                }

                if showFilterBar {
                    HubFilterBar(
                        filter: $filter,
                        projects: projects
                    )
                }

                if client.sessions.isEmpty {
                    HubEmptyState(client: client)
                } else if hasNoMatches {
                    HubEmptyFilterState {
                        withAnimation(.snappy) { filter.clear() }
                    }
                }

                ForEach(visibleBuckets, id: \.self) { bucket in
                    let rows = groups[bucket] ?? []
                    HubSectionBlock(
                        bucket: bucket,
                        rows: rows,
                        client: client,
                        selectedSessionID: selectedSessionID,
                        archivingFinished: archivingFinished,
                        open: open,
                        onAct: runAction,
                        onRequestArchiveFinished: bucket == .finished ? { ids in
                            pendingArchiveIDs = ids
                            confirmArchiveFinished = true
                        } : nil,
                        onError: { actionError = $0 }
                    )
                }

                if let old = groups[.old], !old.isEmpty {
                    HubOldSection(
                        rows: old,
                        expanded: filter.isActive ? .constant(true) : $showOld,
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
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            if !client.state.isConnected && !client.isInProcess {
                client.reconnectNow()
            }
            try? await client.refreshHub()
        }
        .onChange(of: projects) { _, currentProjects in
            guard let selectedDir = filter.selectedDirectory else { return }
            let normalized = HubFilter.normalizedDirectory(selectedDir)
            if !currentProjects.contains(where: { HubFilter.normalizedDirectory($0.directory) == normalized }) {
                filter.selectedDirectory = nil
            }
        }
        .actionErrorAlert($actionError)
        .alert(
            "Archive \(pendingArchiveIDs.count) finished \(pendingArchiveIDs.count == 1 ? "session" : "sessions")?",
            isPresented: $confirmArchiveFinished
        ) {
            Button("Cancel", role: .cancel) {
                pendingArchiveIDs = []
            }
            Button("Archive", role: .destructive) {
                let ids = pendingArchiveIDs
                pendingArchiveIDs = []
                archiveSessions(ids)
            }
        } message: {
            Text("Archived sessions leave the hub and stay searchable on your Mac.")
        }
    }

    private func archiveSessions(_ ids: [String]) {
        guard !ids.isEmpty, !archivingFinished else { return }
        archivingFinished = true
        Task {
            defer { archivingFinished = false }
            var attempted = 0
            var failures: [String] = []
            for id in ids {
                guard let current = client.sessions.first(where: { $0.id == id }),
                      current.roomID == nil,
                      !current.archived,
                      HubBoard.bucket(for: current) == .finished else { continue }
                attempted += 1
                do {
                    try await client.archive(sessionID: id)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if attempted > 0 {
                try? await client.refreshHub()
            }
            if let first = failures.first {
                if failures.count == 1 {
                    actionError = first
                } else {
                    actionError = "Could not archive \(failures.count) of \(attempted) sessions. \(first)"
                }
            }
        }
    }

    private func runAction(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }
}

// MARK: - Filter bar & empty filter state

private struct HubFilterBar: View {
    @Binding var filter: HubFilter
    let projects: [HubProjectOption]

    private var totalProjectSessions: Int {
        projects.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.tertiaryText)
                TextField("Filter sessions...", text: $filter.query)
                    .font(RemoteTheme.font(size: 14.5, relativeTo: .body))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(RemoteTheme.font(size: 15, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                            .frame(minWidth: 32, minHeight: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, filter.query.isEmpty ? 12 : 4)
            .frame(minHeight: 40)
            .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
            )

            if projects.count >= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        projectPill(
                            label: "All",
                            count: totalProjectSessions,
                            needsYouCount: 0,
                            selected: filter.selectedDirectory == nil
                        ) {
                            withAnimation(.snappy) {
                                filter.selectedDirectory = nil
                            }
                        }

                        ForEach(projects) { project in
                            let selected = filter.selectedDirectory.map {
                                HubFilter.normalizedDirectory($0) == project.directory
                            } ?? false
                            projectPill(
                                label: project.label,
                                count: project.count,
                                needsYouCount: project.needsYouCount,
                                selected: selected
                            ) {
                                withAnimation(.snappy) {
                                    filter.selectedDirectory = selected ? nil : project.directory
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func projectPill(
        label: String,
        count: Int,
        needsYouCount: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if needsYouCount > 0 {
                    Circle()
                        .fill(RemoteTheme.warning)
                        .frame(width: 6, height: 6)
                }
                Text(label)
                    .font(RemoteTheme.font(size: 12.5, weight: selected ? .semibold : .medium, relativeTo: .caption))
                    .foregroundStyle(selected ? RemoteTheme.primaryText : RemoteTheme.secondaryText)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(RemoteTheme.font(size: 11, weight: .semibold, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(selected ? RemoteTheme.accent : RemoteTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? RemoteTheme.accent.opacity(0.16) : RemoteTheme.card, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    selected ? RemoteTheme.accent : RemoteTheme.border,
                    lineWidth: selected ? 1.5 : 0.75
                )
            )
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(
            needsYouCount > 0
                ? "\(label), \(count) sessions, \(needsYouCount) needs you"
                : "\(label), \(count) sessions"
        )
    }
}

private struct HubEmptyFilterState: View {
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(RemoteTheme.tertiaryText)
            Text("No sessions match your filter")
                .font(RemoteTheme.font(size: 15.5, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Clear filters", action: onClear)
                .buttonStyle(RemoteSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
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
                .buttonStyle(RemoteSecondaryButtonStyle())
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
    var archivingFinished = false
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    var onRequestArchiveFinished: (([String]) -> Void)? = nil
    let onError: (String) -> Void

    private var archivableIDs: [String] {
        guard bucket == .finished else { return [] }
        return HubFilter.archivableFinishedSessionIDs(from: rows)
    }

    var body: some View {
        let idsToArchive = archivableIDs
        let showArchiveAll = !idsToArchive.isEmpty && client.state.isConnected && onRequestArchiveFinished != nil
        VStack(alignment: .leading, spacing: RemoteTheme.cardGap) {
            HubSectionHeader(
                bucket: bucket,
                count: rows.count,
                trailingLabel: showArchiveAll ? "Archive all" : nil,
                trailingBusy: archivingFinished,
                onTrailingTap: showArchiveAll ? { onRequestArchiveFinished?(idsToArchive) } : nil
            )
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
    var trailingLabel: String? = nil
    var trailingBusy = false
    var onTrailingTap: (() -> Void)? = nil

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
            if let trailingLabel, let onTrailingTap {
                Spacer(minLength: 8)
                Button(action: onTrailingTap) {
                    HStack(spacing: 5) {
                        if trailingBusy {
                            Spinner(size: 10)
                        } else {
                            Image(systemName: "archivebox")
                                .font(RemoteTheme.font(size: 11, weight: .medium, relativeTo: .caption))
                        }
                        Text(trailingBusy ? "Archiving..." : trailingLabel)
                            .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                            .lineLimit(1)
                    }
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RemoteTheme.cardRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
                    .frame(minHeight: RemoteTheme.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(trailingBusy)
                .accessibilityLabel(trailingLabel)
            }
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
                            .lineLimit(1)
                    }
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(RemoteTheme.inlineCodeBackground, in: Capsule())
                    .layoutPriority(1)

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

    @State private var allowHaptic = 0
    @State private var rejectHaptic = 0
    @State private var stopHaptic = 0

    var body: some View {
        Group {
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
                            allowHaptic += 1
                            onAct { try await client.reply(to: ask, decision: .once) }
                        }
                        .buttonStyle(RemotePrimaryButtonStyle())

                        Button("Reject", role: .destructive) {
                            rejectHaptic += 1
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
                    stopHaptic += 1
                    onAct { try await client.interrupt(target) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
            }
        }
        .sensoryFeedback(.success, trigger: allowHaptic)
        .sensoryFeedback(.warning, trigger: rejectHaptic)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopHaptic)
    }
}

private struct HubRoomQuickActions: View {
    let room: RemoteRoom
    let client: RemoteClient
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void
    let onError: (String) -> Void

    @State private var pauseHaptic = 0

    var body: some View {
        let route = ChatRoute(sessionID: room.sessionID, title: room.title)
        Group {
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
                    pauseHaptic += 1
                    onAct { try await client.controlRoom(room.id, action: .pause) }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: pauseHaptic)
    }
}

private struct HubInteractionQuickActions: View {
    let ask: PermissionRequest
    let session: SessionSummary
    let client: RemoteClient
    let open: (ChatRoute) -> Void
    let onAct: (@escaping () async throws -> Void) -> Void

    @State private var allowHaptic = 0
    @State private var rejectHaptic = 0

    var body: some View {
        Group {
            if let plan = ask.plan {
                VStack(alignment: .leading, spacing: 10) {
                    Text(plan.title)
                        .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(3)
                    PlanButtons(plan: plan) { decision in
                        if case .proceed = decision { allowHaptic += 1 } else { rejectHaptic += 1 }
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
                        allowHaptic += 1
                        onAct {
                            try await client.answer(ask, answers: [AgentQuestionAnswer(questionID: question.id, selected: [label])])
                        }
                    }
                    if question.allowsOther {
                        Button("Type an answer") { open(ChatRoute(sessionID: session.id, title: session.title)) }
                            .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .frame(minHeight: RemoteTheme.minTapTarget)
                            .contentShape(Rectangle())
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
        .sensoryFeedback(.success, trigger: allowHaptic)
        .sensoryFeedback(.warning, trigger: rejectHaptic)
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
                    .buttonStyle(RemoteSecondaryButtonStyle(minHeight: RemoteTheme.minTapTarget))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
