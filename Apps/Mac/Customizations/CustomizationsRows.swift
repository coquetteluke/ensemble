import AppKit
import SwiftUI
import EnsembleKit

// Rows of the Customizations screen. Every row shows where the item comes from and whether the engine uses it now;
// files get Open in (installed editors only, never a default-app open) and Reveal in Finder.

/// The card every row sits in.
struct CustomizationCard<Content: View>: View {
    let dimmed: Bool
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(5)) { content }
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(9))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .opacity(dimmed ? 0.72 : 1)
    }
}

/// Title, then the status on the right.
struct CustomizationTitle: View {
    let title: String
    var help: String?
    var monospaced = false
    let status: CustomizationStatus
    var live: CustomizationLiveStatus?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
            Text(title)
                .font(theme.font(size: 12.5, weight: .semibold, design: monospaced ? .monospaced : .default))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(help ?? title)
            Spacer(minLength: theme.z(4))
            CustomizationStatusPill(status: status, live: live)
        }
    }
}

/// A coloured dot and a word: Loaded, On demand, Skipped, Not started, Off, or the engine's own MCP state.
struct CustomizationStatusPill: View {
    let status: CustomizationStatus
    var live: CustomizationLiveStatus?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(4)) {
            StatusDot(color, size: theme.z(6))
            Text(label)
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(help)
    }

    private var label: String {
        if let live, status.isActive { return live.label }
        return status.label
    }

    private var help: String {
        if let live, status.isActive { return live.message ?? live.label }
        return status.detail.map { "\(status.label): \($0)" } ?? status.label
    }

    private var color: Color {
        if let live, status.isActive {
            switch live.state {
            case .connected: return theme.success
            case .needsAuth: return theme.warning
            case .failed: return theme.danger
            case .connecting, .disabled: return theme.textTertiary
            }
        }
        switch status {
        case .loaded: return theme.success
        case .onDemand: return theme.contextBlue
        case .skippedUntrusted, .notStarted: return theme.warning
        case .disabled: return theme.textTertiary
        }
    }
}

/// Small grey labels: scope, kind, transport.
struct CustomizationTags: View {
    let tags: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(4)) {
            ForEach(tags.filter { !$0.isEmpty }, id: \.self) { tag in
                Text(tag)
                    .font(theme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, theme.z(5))
                    .padding(.vertical, theme.z(1.5))
                    .background(RoundedRectangle(cornerRadius: theme.z(4), style: .continuous).fill(theme.hover))
            }
        }
    }
}

/// A secondary line of text (path, note, keys).
struct CustomizationLine: View {
    let text: String
    var monospaced = false
    var color: Color?
    var lines = 1
    var help: String?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 11, design: monospaced ? .monospaced : .default))
            .foregroundStyle(color ?? theme.textTertiary)
            .lineLimit(lines)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .help(help ?? text)
    }
}

/// Open in (each installed editor) and Reveal in Finder for a file.
struct CustomizationFileActions: View {
    let path: String
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: theme.z(10)) {
            if isSnapshot {
                Text("Open in")
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
            } else {
                openInMenu
            }
            Button {
                FileActions.reveal(FileLink(path: path))
            } label: {
                Text("Reveal")
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .help("Show \(path) in Finder")
            Spacer(minLength: 0)
        }
        .padding(.top, theme.z(1))
    }

    private var openInMenu: some View {
        Menu {
            let items = FileActions.openInItems(for: FileLink(path: path))
            if items.isEmpty {
                Text("No code editor found")
            }
            ForEach(items) { item in
                Button(item.title) { item.action?() }
            }
        } label: {
            Text("Open in")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open \(path) in a code editor")
    }
}

// MARK: Rows

extension CustomizationStatus {
    /// Rows explain every status except Loaded and Not started (the Gemini column says that once).
    var showsDetail: Bool { self != .loaded && self != .notStarted }
}

struct CustomizationRuleRow: View {
    let rule: CustomizationRule
    let folder: String
    let home: String
    @Environment(\.theme) private var theme

    var body: some View {
        CustomizationCard(dimmed: !rule.status.isActive) {
            CustomizationTitle(title: rule.isFile ? CustomizationsDiscovery.relativePath(rule.path, to: folder, home: home) : rule.path,
                               help: rule.path, monospaced: true, status: rule.status)
            CustomizationTags(tags: [rule.scope.label, kindLabel, rule.size.map(Self.size) ?? ""])
            if let detail = rule.status.detail, rule.status.showsDetail {
                CustomizationLine(text: detail, color: theme.textSecondary, lines: 2)
            }
            if let note = rule.note {
                CustomizationLine(text: note, lines: 2)
            }
            if !rule.firstLines.isEmpty {
                Text(rule.firstLines.joined(separator: "\n"))
                    .font(theme.font(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.z(7))
                    .padding(.vertical, theme.z(5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(theme.codeBackground))
            }
            if rule.isFile { CustomizationFileActions(path: rule.path) }
        }
    }

    private var kindLabel: String {
        switch rule.kind {
        case .memory: "Memory"
        case .rule: "Rule"
        case .instructions: "Instructions"
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct CustomizationEntryRow: View {
    let entry: CustomizationEntry
    let folder: String
    let home: String
    @Environment(\.theme) private var theme

    var body: some View {
        CustomizationCard(dimmed: !entry.status.isActive) {
            CustomizationTitle(title: entry.name, help: entry.path, monospaced: true, status: entry.status)
            CustomizationTags(tags: [entry.kind.label, entry.scope.label])
            if !entry.summary.isEmpty {
                CustomizationLine(text: entry.summary, color: theme.textSecondary, lines: 3)
            }
            if let note = entry.note {
                CustomizationLine(text: note, lines: 1)
            }
            if let detail = entry.status.detail, entry.status.showsDetail {
                CustomizationLine(text: detail, color: theme.textSecondary, lines: 2)
            }
            CustomizationLine(text: entry.isFile ? CustomizationsDiscovery.relativePath(entry.path, to: folder, home: home) : entry.path,
                              monospaced: true, help: entry.path)
            if entry.isFile { CustomizationFileActions(path: entry.path) }
        }
    }
}

struct CustomizationMCPRow: View {
    let model: CustomizationsModel
    let server: CustomizationMCPServer
    let folder: String
    let home: String
    @Environment(\.theme) private var theme

    var body: some View {
        CustomizationCard(dimmed: !server.status.isActive) {
            CustomizationTitle(title: server.name, status: server.status, live: server.live)
            CustomizationTags(tags: [server.transport == .unknown ? "" : server.transport.label, server.scope.label])
            if !server.target.isEmpty {
                CustomizationLine(text: server.target, monospaced: true, color: theme.textSecondary, lines: 2)
            }
            if !server.environmentKeys.isEmpty {
                CustomizationLine(text: "Environment: " + server.environmentKeys.joined(separator: ", "), lines: 2)
            }
            if !server.headerKeys.isEmpty {
                CustomizationLine(text: "Headers: " + server.headerKeys.joined(separator: ", "), lines: 2)
            }
            if let detail = server.status.detail, server.status.showsDetail {
                CustomizationLine(text: detail, color: theme.textSecondary, lines: 2)
            }
            if let message = server.live?.message, server.status.isActive {
                CustomizationLine(text: message, color: theme.danger, lines: 3)
            }
            if let signIn = model.signIns[server.id] {
                CustomizationLine(text: signIn.instructions.isEmpty ? "Finish signing in in your browser." : signIn.instructions,
                                  color: theme.textSecondary, lines: 3)
            }
            if let error = model.actionErrors[server.id] {
                CustomizationLine(text: error, color: theme.danger, lines: 3)
            }
            if let source = server.sourcePath {
                CustomizationLine(text: CustomizationsDiscovery.relativePath(source, to: folder, home: home), monospaced: true, help: source)
            }
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        let busy = model.busy.contains(server.id)
        if server.canAuthenticate || server.canRestart {
            HStack(spacing: theme.z(8)) {
                if server.canAuthenticate {
                    Button(model.signIns[server.id] == nil ? "Authenticate" : "Waiting\u{2026}") {
                        Task { await model.authenticate(server) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
                    .disabled(busy)
                    .help("Sign in to \(server.name) in your browser")
                }
                if server.canRestart {
                    Button("Restart") { Task { await model.restart(server) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .fixedSize()
                        .disabled(busy)
                        .help("Disconnect \(server.name) and connect it again")
                }
                if busy, model.signIns[server.id] == nil { Spinner(size: theme.z(10)) }
                Spacer(minLength: 0)
            }
            .padding(.top, theme.z(2))
        }
        if let source = server.sourcePath {
            CustomizationFileActions(path: source)
        }
    }
}

struct CustomizationHookRow: View {
    let hook: CustomizationHook
    let folder: String
    let home: String
    @Environment(\.theme) private var theme

    var body: some View {
        CustomizationCard(dimmed: !hook.status.isActive) {
            CustomizationTitle(title: title, status: hook.status)
            CustomizationTags(tags: tags)
            if !hook.command.isEmpty, !(hook.kind == .plugin && hook.handler == "file") {
                Text(hook.command)
                    .font(theme.font(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(hook.command)
            }
            if let detail = hook.status.detail, hook.status.showsDetail {
                CustomizationLine(text: detail, color: theme.textSecondary, lines: 2)
            }
            if let source = hook.sourcePath {
                CustomizationLine(text: CustomizationsDiscovery.relativePath(source, to: folder, home: home), monospaced: true, help: source)
                CustomizationFileActions(path: source)
            }
        }
    }

    private var title: String {
        if hook.kind == .plugin { return hook.name ?? "Plugin" }
        if let matcher = hook.matcher { return "\(hook.event): \(matcher)" }
        return hook.event
    }

    private var tags: [String] {
        if hook.kind == .plugin { return ["Plugin", hook.handler == "package" ? "Package" : "File", hook.scope.label] }
        return [Self.handlerLabel(hook.handler), hook.name.map { "Hook \($0)" } ?? "", hook.scope.label]
    }

    static func handlerLabel(_ handler: String) -> String {
        switch handler {
        case "command": "Command"
        case "http": "HTTP"
        case "prompt": "Prompt"
        case "agent": "Agent"
        case "mcp_tool": "MCP tool"
        default: handler
        }
    }
}
