import EnsembleKit
import SwiftUI

/// The details panel for one chat, the same four sections as the Mac's right-hand panel: Environment (where it
/// runs), Context (how full the model's context is), Outputs (files it changed) and Connectors (MCP servers).
/// The numbers come from the Mac on request, and again whenever the agent stops working.
struct SessionDetailsPanel: View {
    let client: RemoteClient
    let sessionID: String

    @Environment(\.theme) private var theme
    @State private var details: RemoteSessionDetails?
    @State private var loadError: String?
    @State private var showAllOutputs = false
    @State private var showDiffSheet = false

    private var summary: SessionSummary? { client.sessions.first { $0.id == sessionID } }
    private var activity: SessionActivity? {
        client.openTranscript?.sessionID == sessionID ? client.openTranscript?.activity : summary?.activity
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    environmentSection
                    separator
                    contextSection
                    separator
                    outputsSection
                    separator
                    connectorsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RemoteTheme.sidebar.ignoresSafeArea())
        .task(id: "\(sessionID)-\(client.state.isConnected)") { await load() }
        .onChange(of: activity) { old, new in
            // A turn just ended: the context and the changed files are different now.
            if old == .working, new != .working { Task { await load() } }
        }
        .sheet(isPresented: $showDiffSheet) {
            RemoteDiffSheet(client: client, sessionID: sessionID, title: summary?.title ?? "Changes")
                .remoteThemeEnvironment()
        }
    }

    private func load() async {
        guard client.state.isConnected || client.isInProcess else { return }
        do {
            details = try await client.details(sessionID: sessionID)
            loadError = nil
        } catch let error as RemoteError where error.code == .unknownMessage {
            loadError = "Update Ensemble on your Mac to see the context and connectors here."
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Details")
                .font(RemoteTheme.font(size: 16, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.primaryText)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
        }
    }

    // MARK: Environment

    private var environmentSection: some View {
        let directory = details?.directory ?? summary?.directory ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Environment")
            row(icon: "laptopcomputer") {
                Text(details?.macName ?? client.macName)
                    .foregroundStyle(RemoteTheme.primaryText)
            } trailing: {
                Text(connectionLabel)
                    .foregroundStyle(RemoteTheme.secondaryText)
            }
            if !directory.isEmpty {
                row(icon: "folder") {
                    Text("\(Text(Format.folderName(directory)).foregroundStyle(RemoteTheme.primaryText))\(Text(" \u{00B7} \(Format.parentPath(directory))").foregroundStyle(RemoteTheme.secondaryText))")
                        .truncationMode(.middle)
                }
            }
            ForEach(details?.extraFolders ?? [], id: \.self) { folder in
                row(icon: "folder") {
                    Text(Format.folderName(folder)).foregroundStyle(RemoteTheme.primaryText)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var connectionLabel: String {
        if client.isInProcess { return "Demo" }
        switch client.state {
        case .connected(via: .direct): return "Direct"
        case .connected(via: .relay): return "Relay"
        default: return "Offline"
        }
    }

    // MARK: Context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let breakdown = details?.context, breakdown.limitTokens > 0 {
                let main = breakdown.categories.filter { $0.key != "buffer" && $0.key != "free" }
                let reserve = breakdown.categories.filter { $0.key == "buffer" || $0.key == "free" }
                HStack(spacing: 8) {
                    sectionTitle("Context")
                    Spacer(minLength: 8)
                    Text("\(Format.wholePercent(breakdown.fractionUsed)) used")
                        .foregroundStyle(RemoteTheme.primaryText)
                    Text("\(Format.tokens(breakdown.usedTokens)) / \(Format.tokens(breakdown.limitTokens))")
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
                .font(RemoteTheme.font(size: 13, relativeTo: .footnote).monospacedDigit())
                .lineLimit(1)
                DetailsContextBar(breakdown: breakdown)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                ForEach(main) { breakdownRow($0, limit: breakdown.limitTokens) }
                if !reserve.isEmpty {
                    Color.clear.frame(height: main.isEmpty ? 0 : 8)
                    ForEach(reserve) { breakdownRow($0, limit: breakdown.limitTokens) }
                }
            } else {
                sectionTitle("Context")
                note(loadError ?? (details == nil ? "Loading" : "No numbers yet"))
            }
        }
        .padding(.vertical, 8)
    }

    private func breakdownRow(_ category: ContextBreakdown.Category, limit: Int) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(theme.contextColor(for: category.key))
                .frame(width: 10, height: 10)
                .overlay {
                    if category.key == "free" {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(RemoteTheme.border, lineWidth: 1)
                    }
                }
            Text(category.label)
                .foregroundStyle(RemoteTheme.secondaryText)
                .lineLimit(1)
                .padding(.leading, 12)
            Spacer(minLength: 8)
            Text(Format.tokens(category.tokens))
                .foregroundStyle(RemoteTheme.secondaryText)
                .fixedSize()
            Text(Format.percent(category.tokens, of: limit))
                .foregroundStyle(RemoteTheme.primaryText)
                .fixedSize()
                .frame(minWidth: 52, alignment: .trailing)
        }
        .font(RemoteTheme.font(size: 13, relativeTo: .footnote).monospacedDigit())
        .frame(height: 26)
    }

    // MARK: Outputs

    private var outputsSection: some View {
        let files = details?.outputs ?? []
        let shown = showAllOutputs ? files : Array(files.prefix(5))
        let directory = details?.directory ?? summary?.directory ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                sectionTitle("Outputs")
                Spacer(minLength: 8)
                if !files.isEmpty {
                    Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote).monospacedDigit())
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
            }
            if files.isEmpty {
                note(details == nil ? (loadError == nil ? "Loading" : "Not available") : "No files changed yet")
            }
            ForEach(shown) { file in
                Button {
                    showDiffSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: file.kind == .deleted ? "minus.square" : (file.kind == .added ? "plus.square" : "doc.text"))
                            .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                            .frame(width: 18)
                        Text(displayPath(file.path, in: directory))
                            .foregroundStyle(RemoteTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        if file.additions > 0 {
                            Text("+\(file.additions)").foregroundStyle(RemoteTheme.success).fixedSize()
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)").foregroundStyle(RemoteTheme.danger).fixedSize()
                        }
                    }
                    .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote).monospacedDigit())
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the changes")
            }
            if files.count > 5 {
                Button(showAllOutputs ? "Show fewer" : "Show all \(files.count)") { showAllOutputs.toggle() }
                    .buttonStyle(.plain)
                    .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.accent)
                    .frame(minHeight: 36)
            }
        }
        .padding(.vertical, 8)
    }

    private func displayPath(_ path: String, in directory: String) -> String {
        guard !directory.isEmpty, path.hasPrefix(directory) else { return path }
        let relative = path.dropFirst(directory.count)
        return String(relative.drop { $0 == "/" })
    }

    // MARK: Connectors

    private var connectorsSection: some View {
        let connectors = (details?.connectors ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let toReconnect = connectors.count { $0.state == .needsAuth || $0.state == .failed }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                sectionTitle("Connectors")
                Spacer(minLength: 8)
                if toReconnect > 0 {
                    Text("\(toReconnect) to reconnect")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote).monospacedDigit())
                        .foregroundStyle(RemoteTheme.warning)
                } else if !connectors.isEmpty {
                    Text("\(connectors.count { $0.state == .connected }) connected")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote).monospacedDigit())
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
            }
            if connectors.isEmpty {
                note(details == nil ? (loadError == nil ? "Loading" : "Not available") : "No connectors")
            }
            ForEach(connectors) { connector in
                HStack(spacing: 10) {
                    Text(String(connector.name.prefix(1)).uppercased())
                        .font(RemoteTheme.font(size: 10.5, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(RemoteTheme.secondaryText)
                        .frame(width: 18, height: 18)
                        .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(connector.name)
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    connectorState(connector)
                }
                .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                .frame(minHeight: 36)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func connectorState(_ connector: ConnectorInfo) -> some View {
        switch connector.state {
        case .connected:
            HStack(spacing: 6) {
                Text("\(connector.toolCount) tools").foregroundStyle(RemoteTheme.tertiaryText)
                Circle().fill(RemoteTheme.success).frame(width: 7, height: 7)
            }
            .font(RemoteTheme.font(size: 12.5, relativeTo: .caption).monospacedDigit())
        case .needsAuth:
            Text("Sign in on your Mac")
                .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.warning)
        case .failed:
            HStack(spacing: 6) {
                Text("Failed").foregroundStyle(RemoteTheme.secondaryText)
                Circle().fill(RemoteTheme.danger).frame(width: 7, height: 7)
            }
            .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
        case .connecting:
            ConstellationSpinner(size: 16)
        case .disabled:
            Text("Off")
                .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.tertiaryText)
        }
    }

    // MARK: Pieces

    private var separator: some View {
        Rectangle().fill(RemoteTheme.separator).frame(height: 1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(RemoteTheme.font(size: 13.5, weight: .semibold, relativeTo: .footnote))
            .foregroundStyle(RemoteTheme.primaryText)
            .frame(minHeight: 34)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
            .foregroundStyle(RemoteTheme.tertiaryText)
            .frame(minHeight: 32)
    }

    private func row<Label: View, Trailing: View>(icon: String, @ViewBuilder label: () -> Label,
                                                   @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                .foregroundStyle(RemoteTheme.tertiaryText)
                .frame(width: 18)
            label().lineLimit(1)
            Spacer(minLength: 8)
            trailing().lineLimit(1).fixedSize()
        }
        .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
        .frame(minHeight: 36)
    }
}

/// Thin segmented bar: one rounded segment per kind of content, sized by its share of the limit.
private struct DetailsContextBar: View {
    let breakdown: ContextBreakdown
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let limit = CGFloat(max(1, breakdown.limitTokens))
            let used = breakdown.categories.filter { $0.key != "free" && $0.tokens > 0 }
            HStack(spacing: 1) {
                ForEach(used) { category in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.contextColor(for: category.key))
                        .frame(width: max(3, CGFloat(category.tokens) / limit * proxy.size.width - 1))
                }
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: 5, alignment: .leading)
            .background(Capsule().fill(RemoteTheme.track))
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Context \(Format.wholePercent(breakdown.fractionUsed)) used")
    }
}
