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
    @Environment(\.openSettings) private var openSettings
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
                        if !store.safetyCheckDecisions(for: session.id).isEmpty {
                            SafetyCheckPanelSection(store: store, session: session)
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
                Text("This computer")
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
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
                Text("Remote Control")
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            } trailing: {
                Toggle(isOn: $remoteControl) { EmptyView() }
                    .toggleStyle(CompactSwitchStyle())
                    .fixedSize()
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
            HStack(spacing: theme.z(8)) {
                // A model whose window is not known has no share to show: say how much is used and leave it there.
                Text(breakdown.limitTokens > 0
                     ? "\(Format.wholePercent(breakdown.fractionUsed)) used"
                     : "\(Format.tokens(breakdown.usedTokens)) used")
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(8))
                if breakdown.limitTokens > 0 {
                    Text("\(Format.tokens(breakdown.usedTokens)) / \(Format.tokens(breakdown.limitTokens))")
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(theme.font(size: 13))
            .monospacedDigit()
            .frame(height: theme.z(26))

            if breakdown.limitTokens > 0 {
                ContextBar(breakdown: breakdown)
                    .padding(.top, theme.z(1))
                    .padding(.bottom, theme.z(6))
            }

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

            if let session, let line = breakdown.compactingLine {
                ContextCompactRow(line: line,
                                  canCompact: store.engineHasCommand("compact", sessionID: session.id),
                                  working: session.isWorking) {
                    let id = session.id
                    Task { await store.runCommand("compact", arguments: "", in: id) }
                }
                .padding(.top, theme.z(10))
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
                            .strokeBorder(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.1), lineWidth: 1)
                    }
                }
            Color.clear.frame(width: theme.z(13), height: 1)
            Text(category.label)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .overlay(alignment: .bottom) {
                    if Self.dottedKeys.contains(category.key) {
                        DottedLine()
                            .stroke(theme.textSecondary.opacity(0.75), style: StrokeStyle(lineWidth: theme.z(1), dash: [theme.z(1), theme.z(1.5)]))
                            .frame(height: 1)
                            .offset(y: theme.z(0.5))
                    }
                }
            Spacer(minLength: theme.z(8))
            Text(Format.tokens(category.tokens))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if limit > 0 {
                Text(Format.percent(category.tokens, of: limit))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: theme.z(54), alignment: .trailing)
            }
        }
        .font(theme.font(size: 13))
        .monospacedDigit()
        .frame(height: theme.z(23))
    }

    /// Categories whose rows carry the dotted underline in the reference (they have item lists).
    static let dottedKeys: Set<String> = ["mcp", "mcpTools", "skills", "mcpInstructions", "memory", "agents"]

    private struct DisclosureGroupInfo {
        struct Item: Identifiable {
            let id: String
            let name: String
            let value: String
            let sessionID: String?
        }

        let title: String
        let count: Int
        let items: [Item]
    }

    private var disclosureGroups: [DisclosureGroupInfo] {
        var groups: [DisclosureGroupInfo] = []
        let connected = store.connectors.filter { $0.state == .connected && $0.toolCount > 0 }
        if !connected.isEmpty {
            groups.append(DisclosureGroupInfo(title: "MCP tools", count: connected.reduce(0) { $0 + $1.toolCount },
                                              items: connected.map { .init(id: "mcp:\($0.id)", name: $0.name, value: "\($0.toolCount)", sessionID: nil) }))
        }
        if let session {
            let children = store.children(of: session.id)
            if !children.isEmpty {
                groups.append(DisclosureGroupInfo(title: "Subagents", count: children.count,
                                                  items: children.map { .init(id: "sub:\($0.id)", name: $0.title, value: Format.tokens($0.usage.inputTokens + $0.usage.outputTokens), sessionID: $0.id) }))
            }
            let agentIDs = store.sessionAgentIDs[session.id] ?? []
            if agentIDs.count > 1 {
                let agents = agentIDs.compactMap { store.agents[$0] }
                groups.append(DisclosureGroupInfo(title: "Agents", count: agents.count,
                                                  items: agents.map { .init(id: "agent:\($0.id.uuidString)", name: $0.name, value: $0.model.id, sessionID: nil) }))
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
                    Text(group.title)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: theme.z(8))
                    Text("\(group.count)")
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(theme.font(size: 13))
                .monospacedDigit()
                .frame(height: theme.z(23))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(group.items) { item in
                    DisclosureItemRow(name: item.name, value: item.value, clickable: item.sessionID != nil) {
                        if let id = item.sessionID { store.select(id) }
                    }
                }
            }
        }
    }

    // MARK: Outputs

    private var outputsSection: some View {
        let files = session?.changedFiles ?? []
        let shown = showAllOutputs ? files : Array(files.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text("Outputs")
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(8))
                if !files.isEmpty {
                    Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(theme.font(size: 13))
            .frame(height: theme.z(30))

            if files.isEmpty {
                Text("No files changed yet")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .frame(height: theme.z(31))
            }
            ForEach(shown) { file in
                OutputFileRow(file: file, baseDirectory: session?.directory ?? "") {
                    diffFile = file
                }
                .popover(item: diffBinding(for: file), arrowEdge: .leading) { file in
                    FileDiffPopover(file: file, baseDirectory: session?.directory ?? "")
                        .ensembleTheme()
                }
            }
            if files.count > 5 {
                Button(showAllOutputs ? "Show fewer" : "Show all \(files.count)") { showAllOutputs.toggle() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .frame(height: theme.z(28))
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
                    Text("Connectors")
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Glyph(isConnectorsExpanded ? .chevronDown : .chevronRight, size: 13)
                    Spacer(minLength: theme.z(8))
                    if !isConnectorsExpanded {
                        if toReconnect > 0 {
                            Text("\(toReconnect) to reconnect")
                                .foregroundStyle(theme.textSecondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        } else if !connectors.isEmpty {
                            Text("\(connectors.count) connected")
                                .foregroundStyle(theme.textSecondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
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
                    Button(showAllConnectors ? "Show fewer" : "Show all \(connectors.count)") { showAllConnectors.toggle() }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .frame(height: theme.z(28))
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
                Button("Authenticate") {
                    CustomizationsFocus.shared.show(folder: session?.directory)
                    openSettings()
                }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.warning)
                    .underline()
                    .lineLimit(1)
                    .fixedSize()
                    .help("Sign in to \(connector.name)")
            case .failed:
                HStack(spacing: theme.z(6)) {
                    Text("Failed").foregroundStyle(theme.textSecondary).lineLimit(1)
                    StatusDot(theme.danger)
                }
                .font(theme.font(size: 12.5))
                .fixedSize()
            case .connected:
                HStack(spacing: theme.z(6)) {
                    Text("\(connector.toolCount) tools").foregroundStyle(theme.textTertiary).lineLimit(1)
                    StatusDot(theme.success)
                }
                .font(theme.font(size: 12.5))
                .monospacedDigit()
                .fixedSize()
            case .connecting:
                Spinner(size: 10)
            case .disabled:
                Text("Off")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: theme.z(32))
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(theme.font(size: 13))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .frame(height: theme.z(30))
    }
}

private struct DisclosureItemRow: View {
    let name: String
    let value: String
    let clickable: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(8)) {
                Text(name)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(8))
                Text(value)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(theme.font(size: 12.5))
            .monospacedDigit()
            .padding(.leading, theme.z(23))
            .padding(.trailing, theme.z(6))
            .frame(height: theme.z(22))
            .background(
                RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                    .fill(clickable && hovering ? theme.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!clickable)
        .padding(.trailing, theme.z(-6))
        .onHover { hovering = $0 }
    }
}

private struct OutputFileRow: View {
    let file: FileChange
    let baseDirectory: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PanelRow(glyph: Glyph.kind(forPath: file.path)) {
                Text((file.path as NSString).lastPathComponent)
                    .foregroundStyle(file.kind == .deleted ? theme.textTertiary : theme.textPrimary)
                    .strikethrough(file.kind == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } trailing: {
                if file.additions > 0 || file.deletions > 0 {
                    HStack(spacing: theme.z(4)) {
                        if file.additions > 0 {
                            Text("+\(file.additions)").foregroundStyle(theme.diffAddText)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)").foregroundStyle(theme.diffRemoveText)
                        }
                    }
                    .font(theme.font(size: 11.5).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .padding(.horizontal, theme.z(6))
            .background(
                RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                    .fill(hovering ? theme.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, theme.z(-6))
        .onHover { hovering = $0 }
        .help("\(Format.relativePath(file.path, base: baseDirectory)), +\(file.additions) -\(file.deletions)")
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
            let gap = theme.z(1)
            let minSegment = theme.z(3)
            HStack(spacing: gap) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: theme.z(2), style: .continuous)
                        .fill(theme.contextColor(for: segment.key == "other" ? "skills" : segment.key))
                        .frame(width: max(minSegment, CGFloat(segment.tokens) / CGFloat(limit) * width - gap))
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: theme.z(4), alignment: .leading)
            .background(Capsule().fill(theme.track))
            .clipShape(Capsule())
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
                Text("+\(file.additions)").foregroundStyle(theme.diffAddText).fixedSize()
                Text("-\(file.deletions)").foregroundStyle(theme.diffRemoveText).fixedSize()
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

/// Foot of the Context card: how much room is left before the engine compacts the conversation by itself, and a
/// button that compacts it now (the engine's own compact command; hidden when the engine has none).
struct ContextCompactRow: View {
    let line: String
    let canCompact: Bool
    /// The agent is working: compacting waits for the turn to end.
    let working: Bool
    let compact: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Text(line)
                .font(theme.font(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: theme.z(6))
            if canCompact {
                Button("Compact", action: compact)
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(working)
                    .help(working ? "Compacting waits until the agent stops" : "Summarize the conversation so far to free up context")
            }
        }
    }
}
