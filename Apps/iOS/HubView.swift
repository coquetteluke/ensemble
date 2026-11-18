import EnsembleKit
import SwiftUI

/// Session Hub: every session and room sorted into Needs you, Running and Finished, with quick actions.
struct HubView: View {
    let client: RemoteClient
    /// Highlighted row (the chat open in the detail column on the inner screen).
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void
    @State private var showOld = false
    @State private var actionError: String?

    private var groups: [HubBucket: [SessionSummary]] { HubBoard.group(client.sessions) }
    private var visibleBuckets: [HubBucket] {
        let g = groups
        return [HubBucket.needsYou, .running, .finished].filter { !(g[$0] ?? []).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if client.sessions.isEmpty {
                    emptyState
                }
                ForEach(visibleBuckets, id: \.self) { bucket in
                    let rows = groups[bucket] ?? []
                    VStack(alignment: .leading, spacing: 10) {
                        section(bucket.label, count: rows.count)
                        ForEach(rows) { row($0, bucket: bucket) }
                    }
                }
                if let old = groups[.old], !old.isEmpty {
                    Button {
                        withAnimation(.snappy) { showOld.toggle() }
                    } label: {
                        HStack {
                            Text(showOld ? "Hide older" : "Show older (\(old.count))")
                            Image(systemName: showOld ? "chevron.up" : "chevron.down")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(RemoteTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if showOld {
                        ForEach(old) { row($0, bucket: .old) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .remoteScreen()
        .navigationTitle("Session Hub")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(client: client) } }
        .refreshable { try? await client.refreshHub() }
        .actionErrorAlert($actionError)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(RemoteTheme.tertiaryText)
            Text(client.state.isConnected ? "No sessions yet" : "Waiting for your Mac")
                .font(.headline)
                .foregroundStyle(RemoteTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(RemoteTheme.tertiaryText)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(RemoteTheme.secondaryText)
        .padding(.top, 14)
        .padding(.leading, 4)
    }

    private func row(_ s: SessionSummary, bucket: HubBucket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                open(ChatRoute(sessionID: s.id, title: s.title))
            } label: {
                HubRowHeader(session: s, bucket: bucket)
            }
            .buttonStyle(.plain)
            quickActions(s, bucket: bucket)
        }
        .remoteCard(selected: s.id == selectedSessionID)
    }

    @ViewBuilder
    private func quickActions(_ s: SessionSummary, bucket: HubBucket) -> some View {
        if let ask = client.pendingPermissions(for: s.id).first, PermissionDisplay.fitsQuickApproval(ask) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ask.title)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    Button("Allow once") { reply(ask, .once) }
                        .buttonStyle(.borderedProminent)
                    Button("Reject", role: .destructive) { reply(ask, .reject) }
                        .buttonStyle(.bordered)
                        .tint(RemoteTheme.danger)
                }
                .controlSize(.small)
            }
        } else if bucket == .running {
            Button {
                act { try await client.interrupt(target(for: s)) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func target(for s: SessionSummary) -> RemoteTarget {
        s.roomID.map { .room($0) } ?? .session(s.id)
    }

    private func reply(_ request: PermissionRequest, _ decision: PermissionDecision) {
        act { try await client.reply(to: request, decision: decision) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }
}

struct HubRowHeader: View {
    let session: SessionSummary
    let bucket: HubBucket

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(RemoteFormat.age(session.lastActivity))
                        .font(.caption)
                        .foregroundStyle(RemoteTheme.tertiaryText)
                }
                HStack(spacing: 6) {
                    if session.roomID != nil {
                        Image(systemName: "person.2.fill").font(.caption2)
                    }
                    Text(RemoteFormat.folderName(session.directory))
                    if !session.agentNames.isEmpty {
                        Text("·")
                        Text(session.agentNames.joined(separator: ", "))
                    }
                }
                .font(.caption)
                .foregroundStyle(RemoteTheme.secondaryText)
                .lineLimit(1)
                if let ask = session.pendingAsk, bucket == .needsYou {
                    Text(ask)
                        .font(.footnote)
                        .foregroundStyle(RemoteTheme.warning)
                        .lineLimit(2)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RemoteTheme.tertiaryText)
                .padding(.top, 4)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        switch bucket {
        case .needsYou:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(RemoteTheme.warning)
        case .running:
            ProgressView().controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle").foregroundStyle(RemoteTheme.success)
        case .old:
            Image(systemName: "clock").foregroundStyle(RemoteTheme.tertiaryText)
        }
    }
}
