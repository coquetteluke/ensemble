import SwiftUI
import EnsembleKit

/// Right-hand context panel: Environment, Context, Background (while the session has running work), Outputs, Connectors.
/// Sizes follow the reference panel (300 pt wide, 13 pt text, 31 pt rows, 23 pt breakdown rows).
struct ContextPanelView: View {
    let store: SessionStore
    let session: SessionModel?
    @Binding var remoteControl: Bool
    /// Space left for the title bar (the panel toggle sits there). Snapshots of the panel alone use less.
    var topInset: CGFloat = 52
    /// Snapshots can show the connectors list open.
    var connectorsInitiallyExpanded = false
    /// Snapshots pass a fixed time for the Background section's elapsed times.
    var backgroundNow: Date?

    @Environment(\.theme) private var theme
    @State private var showAllOutputs = false
    @State private var connectorsExpanded: Bool?
    @State private var showAllConnectors = false
    @State private var expandedGroups: Set<String> = []
    @State private var diffFile: FileChange?

    static let hostName: String = {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }()

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    environmentSection
                    PanelSeparator()
                    contextSection
                    PanelSeparator()
                    if let session {
                        let running = store.backgroundWork(forSession: session.id)
                        if !running.isEmpty {
                            BackgroundPanelSection(store: store, session: session, items: running, now: backgroundNow)
                            PanelSeparator()
                        }
                    }
                    outputsSection
                    PanelSeparator()
                    connectorsSection
                }
                .padding(.leading, theme.z(12))
                .padding(.trailing, theme.z(14))
                .padding(.bottom, theme.z(24))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
    }

    // MARK: Environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Environment")
            PanelRow(glyph: .laptop) {
                Text("This computer").foregroundStyle(theme.textPrimary)
            } trailing: {
                Button("Save") {}
                    .buttonStyle(.plain)
                    .underline()
                    .foregroundStyle(theme.textPrimary)
                    .help("Save this environment")
            }
            .help("Local session, \(Self.hostName)")

            if let session {
                PanelRow(glyph: .folder) {
                    Text("\(Text(Format.folderName(session.directory)).foregroundStyle(theme.textPrimary))\(Text(" \u{00B7} \(Format.parentPath(session.directory))").foregroundStyle(theme.textSecondary))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(session.directory)

                ForEach(store.extraFolders[session.id] ?? [], id: \.self) { folder in
                    PanelRow(glyph: .folder) {
                        Text(Format.folderName(folder)).foregroundStyle(theme.textPrimary).lineLimit(1)
                    }
                    .help(folder)
                }
            }

            PanelRow(glyph: .monitor) {
                Text("Remote Control").foregroundStyle(theme.textPrimary)
            } trailing: {
                Toggle(isOn: $remoteControl) { EmptyView() }
                    .toggleStyle(CompactSwitchStyle())
                    .accessibilityLabel("Remote Control")
            }
            .help("Let the Ensemble iPhone app control this Mac over Tailscale")
        }
        .padding(.top, theme.z(8))
        .padding(.bottom, theme.z(8))
    }

    // MARK: Context

    private var breakdown: ContextBreakdown {
        session.map { store.contextBreakdown(for: $0) } ?? ContextBreakdown(usedTokens: 0, limitTokens: 0, categories: [])
    }

    private var contextSection: some View {
        let breakdown = breakdown
        let main = breakdown.categories.filter { $0.key != "buffer" && $0.key != "free" }
        let reserve = breakdown.categories.filter { $0.key == "buffer" || $0.key == "free" }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Context")
            HStack {
                Text("\(Format.wholePercent(breakdown.fractionUsed)) used")
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(Format.tokens(breakdown.usedTokens)) / \(Format.tokens(breakdown.limitTokens))")
                    .foregroundStyle(theme.textSecondary)
            }
            .font(theme.font(size: 13))
            .monospacedDigit()
            .frame(height: theme.z(26))

            ContextBar(breakdown: breakdown)
                .padding(.top, theme.z(1))
                .padding(.bottom, theme.z(6))

            ForEach(main) { category in
                breakdownRow(category, limit: breakdown.limitTokens)
            }
            if !reserve.isEmpty {
                Color.clear.frame(height: main.isEmpty ? 0 : theme.z(23))
                ForEach(reserve) { category in
                    breakdownRow(category, limit: breakdown.limitTokens)
                }
            }

            let groups = disclosureGroups
            if !groups.isEmpty {
                Color.clear.frame(height: theme.z(6))
                ForEach(groups, id: \.title) { group in
                    disclosureRow(group)
                }
            }
        }
        .padding(.top, theme.z(8))
        .padding(.bottom, theme.z(14))
    }

    private func breakdownRow(_ category: ContextBreakdown.Category, limit: Int) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: theme.z(2.5), style: .continuous)
                .fill(theme.contextColor(for: category.key))
                .frame(width: theme.z(10), height: theme.z(10))
                .overlay {
                    if category.key == "free" {
                        RoundedRectangle(cornerRadius: theme.z(2.5), style: .continuous)
                            .strokeBorder(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.06), lineWidth: 1)
                    }
                }
            Color.clear.frame(width: theme.z(13), height: 1)
            Text(category.label)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .overlay(alignment: .bottom) {
                    if Self.dottedKeys.contains(category.key) {
                        DottedLine()
                            .stroke(theme.textSecondary.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [1, 1.5]))
                            .frame(height: 1)
                            .offset(y: theme.z(0.5))
                    }
                }
            Spacer(minLength: theme.z(8))
            Text(Format.tokens(category.tokens))
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
            Text(Format.percent(category.tokens, of: limit))
                .foregroundStyle(theme.textPrimary)
                .frame(width: theme.z(54), alignment: .trailing)
        }
        .font(theme.font(size: 13))
        .monospacedDigit()
        .frame(height: theme.z(23))
    }

    /// Categories whose rows carry the dotted underline in the reference (they have item lists).
    static let dottedKeys: Set<String> = ["mcp", "mcpTools", "skills", "mcpInstructions", "memory", "agents"]

    private struct DisclosureGroupInfo {
        let title: String
        let count: Int
        let items: [(name: String, value: String, sessionID: String?)]
    }

    private var disclosureGroups: [DisclosureGroupInfo] {
        var groups: [DisclosureGroupInfo] = []
        let connected = store.connectors.filter { $0.state == .connected && $0.toolCount > 0 }
        if !connected.isEmpty {
            groups.append(DisclosureGroupInfo(title: "MCP tools", count: connected.reduce(0) { $0 + $1.toolCount },
                                              items: connected.map { ($0.name, "\($0.toolCount)", nil) }))
        }
        if let session {
            let children = store.children(of: session.id)
            if !children.isEmpty {
                groups.append(DisclosureGroupInfo(title: "Subagents", count: children.count,
                                                  items: children.map { ($0.title, Format.tokens($0.usage.inputTokens + $0.usage.outputTokens), $0.id) }))
            }
            let agentIDs = store.sessionAgentIDs[session.id] ?? []
            if agentIDs.count > 1 {
                let agents = agentIDs.compactMap { store.agents[$0] }
                groups.append(DisclosureGroupInfo(title: "Agents", count: agents.count,
                                                  items: agents.map { ($0.name, $0.model.id, nil) }))
            }
        }
        return groups
    }

    private func disclosureRow(_ group: DisclosureGroupInfo) -> some View {
        let open = expandedGroups.contains(group.title)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expandedGroups.remove(group.title) } else { expandedGroups.insert(group.title) }
            } label: {
                HStack(spacing: 0) {
                    Glyph(.chevronRight, size: 12)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: theme.z(10))
                    Color.clear.frame(width: theme.z(13), height: 1)
                    Text(group.title).foregroundStyle(theme.textSecondary)
                    Spacer(minLength: theme.z(8))
                    Text("\(group.count)").foregroundStyle(theme.textTertiary)
                }
                .font(theme.font(size: 13))
                .monospacedDigit()
                .frame(height: theme.z(23))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    Button {
                        if let id = item.sessionID { store.select(id) }
                    } label: {
                        HStack {
                            Text(item.name).foregroundStyle(theme.textSecondary).lineLimit(1)
                            Spacer(minLength: theme.z(8))
                            Text(item.value).foregroundStyle(theme.textTertiary)
                        }
                        .font(theme.font(size: 12.5))
                        .monospacedDigit()
                        .padding(.leading, theme.z(23))
                        .frame(height: theme.z(22))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.sessionID == nil)
                }
            }
        }
    }

    // MARK: Outputs

    private var outputsSection: some View {
        let files = session?.changedFiles ?? []
        let shown = showAllOutputs ? files : Array(files.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Outputs")
            if files.isEmpty {
                Text("No files changed yet")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .frame(height: theme.z(31))
            }
            ForEach(shown) { file in
                Button {
                    diffFile = file
                } label: {
                    PanelRow(glyph: Glyph.kind(forPath: file.path)) {
                        Text((file.path as NSString).lastPathComponent)
                            .foregroundStyle(file.kind == .deleted ? theme.textTertiary : theme.textPrimary)
                            .strikethrough(file.kind == .deleted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(Format.relativePath(file.path, base: session?.directory ?? "")), +\(file.additions) -\(file.deletions)")
                .popover(item: diffBinding(for: file), arrowEdge: .leading) { file in
                    FileDiffPopover(file: file, baseDirectory: session?.directory ?? "")
                        .ensembleTheme()
                }
            }
            if files.count > 5 {
                Button(showAllOutputs ? "Show less" : "Show more") { showAllOutputs.toggle() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(height: theme.z(31))
            }
        }
        .padding(.top, theme.z(8))
        .padding(.bottom, theme.z(8))
    }

    private func diffBinding(for file: FileChange) -> Binding<FileChange?> {
        Binding(get: { diffFile?.id == file.id ? diffFile : nil }, set: { diffFile = $0 })
    }

    // MARK: Connectors

    private var isConnectorsExpanded: Bool { connectorsExpanded ?? connectorsInitiallyExpanded }

    private var connectorsSection: some View {
        let connectors = store.connectors.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let toReconnect = connectors.filter { $0.state == .needsAuth || $0.state == .failed }.count
        let shown = showAllConnectors ? connectors : Array(connectors.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { connectorsExpanded = !isConnectorsExpanded }
            } label: {
                HStack(spacing: theme.z(6)) {
                    Text("Connectors").foregroundStyle(theme.textPrimary)
                    Glyph(isConnectorsExpanded ? .chevronDown : .chevronRight, size: 13)
                    Spacer(minLength: theme.z(8))
                    if !isConnectorsExpanded {
                        if toReconnect > 0 {
                            Text("\(toReconnect) to reconnect").foregroundStyle(theme.textSecondary)
                        } else if !connectors.isEmpty {
                            Text("\(connectors.count) connected").foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .font(theme.font(size: 13))
                .frame(height: theme.z(30))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isConnectorsExpanded {
                if connectors.isEmpty {
                    Text("No connectors")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textTertiary)
                        .frame(height: theme.z(32))
                }
                ForEach(shown) { connector in
                    connectorRow(connector)
                }
                if connectors.count > 3 {
                    Button(showAllConnectors ? "Show less" : "Show more") { showAllConnectors.toggle() }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .frame(height: theme.z(32))
                }
            }
        }
        .padding(.top, theme.z(8))
        .padding(.bottom, theme.z(8))
    }

    private func connectorRow(_ connector: ConnectorInfo) -> some View {
        HStack(spacing: 0) {
            LetterAvatar(connector.name, size: 16)
            Color.clear.frame(width: theme.z(13), height: 1)
            Text(connector.name)
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: theme.z(8))
            switch connector.state {
            case .needsAuth:
                Button("Authenticate") {}
                    .buttonStyle(.plain)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.warning)
                    .help("Sign in to \(connector.name)")
            case .failed:
                HStack(spacing: theme.z(6)) {
                    Text("Failed").foregroundStyle(theme.textSecondary)
                    StatusDot(theme.danger)
                }
                .font(theme.font(size: 13))
            case .connected:
                HStack(spacing: theme.z(6)) {
                    Text("\(connector.toolCount) tools").foregroundStyle(theme.textTertiary)
                    StatusDot(theme.success)
                }
                .font(theme.font(size: 12.5))
            case .connecting:
                Spinner(size: 10)
            case .disabled:
                Text("Off")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(height: theme.z(32))
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(theme.font(size: 13))
            .foregroundStyle(theme.textPrimary)
            .frame(height: theme.z(30))
    }
}

/// Icon column plus label, 31 pt tall (Environment and Outputs rows).
struct PanelRow<Label: View, Trailing: View>: View {
    let glyph: Glyph.Kind
    @ViewBuilder let label: Label
    @ViewBuilder let trailing: Trailing
    @Environment(\.theme) private var theme

    init(glyph: Glyph.Kind, @ViewBuilder label: () -> Label, @ViewBuilder trailing: () -> Trailing) {
        self.glyph = glyph
        self.label = label()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            Glyph(glyph, size: 18)
                .frame(width: theme.z(18))
            Color.clear.frame(width: theme.z(11), height: 1)
            label
            Spacer(minLength: theme.z(8))
            trailing
        }
        .font(theme.font(size: 13))
        .frame(height: theme.z(31))
    }
}

extension PanelRow where Trailing == EmptyView {
    init(glyph: Glyph.Kind, @ViewBuilder label: () -> Label) {
        self.init(glyph: glyph, label: label, trailing: { EmptyView() })
    }
}

/// Thin segmented bar like the reference: one rounded segment per colour (neighbouring categories with the
/// same colour merge), sized by share of the limit, 1 pt apart. Buffer is grey; free space is the track.
struct ContextBar: View {
    let breakdown: ContextBreakdown
    @Environment(\.theme) private var theme

    private struct Segment: Identifiable {
        let id: Int
        let key: String
        var tokens: Int
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for category in breakdown.categories where category.key != "free" && category.tokens > 0 {
            let colorKey = Self.colorGroup(category.key)
            if let last = result.last, last.key == colorKey {
                result[result.count - 1].tokens += category.tokens
            } else {
                result.append(Segment(id: result.count, key: colorKey, tokens: category.tokens))
            }
        }
        return result
    }

    /// Categories drawn in the same colour share a segment.
    static func colorGroup(_ key: String) -> String {
        switch key {
        case "messages", "systemTools", "systemPrompt", "buffer": key
        case "tools", "mcp", "mcpTools": "tools"
        default: "other"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let limit = max(1, breakdown.limitTokens)
            HStack(spacing: theme.z(1)) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: theme.z(2), style: .continuous)
                        .fill(theme.contextColor(for: segment.key == "other" ? "skills" : segment.key))
                        .frame(width: max(3, CGFloat(segment.tokens) / CGFloat(limit) * width - 1))
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .background(Capsule().fill(theme.track))
        }
        .frame(height: theme.z(4))
        .accessibilityElement()
        .accessibilityLabel("Context \(Format.wholePercent(breakdown.fractionUsed)) used")
    }
}

/// Separator between panel sections.
struct PanelSeparator: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.isDark ? Color(hex: 0x252525) : theme.separator).frame(height: 1)
    }
}

/// Horizontal line shape for the dotted underline.
struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

/// Diff of one changed file, opened from Outputs.
struct FileDiffPopover: View {
    let file: FileChange
    let baseDirectory: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text(Format.relativePath(file.path, base: baseDirectory))
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: theme.z(8))
                Text("+\(file.additions)").foregroundStyle(theme.diffAddText)
                Text("-\(file.deletions)").foregroundStyle(theme.diffRemoveText)
            }
            .font(theme.font(size: 12, weight: .medium).monospacedDigit())
            .padding(theme.z(12))
            HLine()
            if let diff = file.diff, !diff.isEmpty {
                ScrollView {
                    DiffView(diff: diff, maxLines: nil)
                }
                .frame(maxHeight: theme.z(460))
            } else {
                Text(file.kind == .deleted ? "File deleted" : "No diff available for this file")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
                    .padding(theme.z(16))
            }
        }
        .frame(width: theme.z(520))
        .background(theme.codeBackground)
    }
}
