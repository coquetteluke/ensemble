import AppKit
import SwiftUI
import EnsembleKit

/// One screen that shows, for a folder, what Claude, OpenCode and Gemini load side by side: rules and memory, skills
/// (with commands and agents), MCP servers and hooks, plus what each skips while the folder is not trusted. Read only
/// apart from Trust this folder, Authenticate, Restart and the Open in and Reveal actions.
struct CustomizationsView: View {
    @Bindable var model: CustomizationsModel
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, theme.z(16))
                .padding(.top, theme.z(14))
                .padding(.bottom, theme.z(10))
            sectionTabs
                .padding(.horizontal, theme.z(16))
                .padding(.bottom, theme.z(10))
            HLine()
            content
        }
        .background(theme.background)
        .task(id: loadKey) { await model.load() }
    }

    /// Reloads when the folder or its trust changes.
    private var loadKey: String { "\(model.folder ?? "")|\(model.isTrusted)" }

    // MARK: Header

    private var header: some View {
        HStack(spacing: theme.z(10)) {
            folderMenu
            trustBadge
            if model.loading {
                Spinner(size: theme.z(11))
            }
            Spacer(minLength: 0)
            if let server = model.report?.openCodeServer {
                Text("OpenCode status from \(server)")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            IconButton("arrow.clockwise", help: "Read the folder again", size: theme.z(26)) {
                Task { await model.load() }
            }
            .disabled(model.isFixed)
        }
    }

    /// Rules and memory, Skills, MCP servers, Hooks, Trust.
    private var sectionTabs: some View {
        HStack(spacing: theme.z(2)) {
            ForEach(CustomizationsModel.Section.allCases) { section in
                let selected = model.section == section
                Button {
                    model.section = section
                } label: {
                    Text(section.label)
                        .font(theme.font(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, theme.z(10))
                        .padding(.vertical, theme.z(5))
                        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                            .fill(selected ? theme.selection : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(theme.z(2))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.hover))
    }

    @ViewBuilder private var folderMenu: some View {
        if isSnapshot {
            folderLabel
        } else {
            Menu {
                ForEach(model.recentFolders, id: \.self) { folder in
                    Button(Format.abbreviatedPath(folder)) { model.folder = folder }
                }
                if !model.recentFolders.isEmpty { Divider() }
                Button("Choose Folder\u{2026}") { model.chooseFolder() }
            } label: {
                folderLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help(model.folder ?? "Choose the folder to show")
        }
    }

    private var folderLabel: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: "folder")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text(model.folder.map(Format.abbreviatedPath) ?? "Choose a folder")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            Image(systemName: "chevron.down")
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var trustBadge: some View {
        let trusted = model.isTrusted
        return HStack(spacing: theme.z(5)) {
            Image(systemName: trusted ? "checkmark.shield" : "lock.shield")
                .font(theme.font(size: 11, weight: .medium))
            Text(trusted ? "Trusted" : "Not trusted")
                .font(theme.font(size: 11.5, weight: .medium))
        }
        .foregroundStyle(trusted ? theme.success : theme.warning)
        .padding(.horizontal, theme.z(8))
        .padding(.vertical, theme.z(3))
        .background(Capsule().fill((trusted ? theme.success : theme.warning).opacity(0.12)))
        .opacity(model.folder == nil ? 0 : 1)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.folder == nil {
            Text("Choose a folder to see what each agent loads there.")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.report {
            AdaptiveScroll {
                VStack(alignment: .leading, spacing: theme.z(12)) {
                    if model.section == .trust {
                        CustomizationsTrustSection(model: model, summary: report.trust)
                    } else {
                        if let note = model.liveNote, model.section == .mcp {
                            Text(note)
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }
                        columns(report)
                    }
                }
                .padding(theme.z(16))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack { Spinner(size: theme.z(14)) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func columns(_ report: CustomizationsReport) -> some View {
        HStack(alignment: .top, spacing: theme.z(12)) {
            ForEach(CustomizationEngine.allCases) { engine in
                CustomizationsColumn(model: model, report: report, engine: engine)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// One engine's items for the chosen section.
struct CustomizationsColumn: View {
    let model: CustomizationsModel
    let report: CustomizationsReport
    let engine: CustomizationEngine
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(6)) {
                Text(engine.displayName)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(countText)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, theme.z(2))
            if engine == .gemini, !report.trusted {
                Text("Gemini only starts in folders you trust.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isEmpty {
                Text("None")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
            rows
        }
    }

    @ViewBuilder private var rows: some View {
        let folder = report.folder
        switch model.section {
        case .rules:
            ForEach(report.rules(for: engine)) { rule in
                CustomizationRuleRow(rule: rule, folder: folder, home: model.home)
            }
        case .skills:
            ForEach(sortedEntries) { entry in
                CustomizationEntryRow(entry: entry, folder: folder, home: model.home)
            }
        case .mcp:
            ForEach(report.mcpServers(for: engine)) { server in
                CustomizationMCPRow(model: model, server: server, folder: folder, home: model.home)
            }
        case .hooks:
            ForEach(report.hooks(for: engine)) { hook in
                CustomizationHookRow(hook: hook, folder: folder, home: model.home)
            }
        case .trust:
            EmptyView()
        }
    }

    /// Skills first, then commands, then agents; inside each, project items before user, plugin and built-in ones.
    private var sortedEntries: [CustomizationEntry] {
        func rank(_ scope: CustomizationScope) -> Int {
            switch scope {
            case .project, .local: 0
            case .user: 1
            case .plugin: 2
            case .builtIn: 3
            }
        }
        let kinds = CustomizationEntry.Kind.allCases
        return report.entries(for: engine).enumerated().sorted { a, b in
            let ka = kinds.firstIndex(of: a.element.kind) ?? 0, kb = kinds.firstIndex(of: b.element.kind) ?? 0
            if ka != kb { return ka < kb }
            let ra = rank(a.element.scope), rb = rank(b.element.scope)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var isEmpty: Bool {
        switch model.section {
        case .rules: report.rules(for: engine).isEmpty
        case .skills: report.entries(for: engine).isEmpty
        case .mcp: report.mcpServers(for: engine).isEmpty
        case .hooks: report.hooks(for: engine).isEmpty
        case .trust: true
        }
    }

    private var countText: String {
        let counts = report.counts(for: engine)
        func count(_ number: Int, _ one: String, _ many: String) -> String { "\(number) \(number == 1 ? one : many)" }
        switch model.section {
        case .rules: return "\(counts.rules)"
        case .skills:
            var parts = [count(counts.skills, "skill", "skills")]
            if counts.commands > 0 { parts.append(count(counts.commands, "command", "commands")) }
            if counts.agents > 0 { parts.append(count(counts.agents, "agent", "agents")) }
            return parts.joined(separator: ", ")
        case .mcp: return "\(counts.mcpServers)"
        case .hooks:
            guard counts.plugins > 0 else { return "\(counts.hooks)" }
            return count(counts.hooks, "hook", "hooks") + ", " + count(counts.plugins, "plugin", "plugins")
        case .trust: return ""
        }
    }
}

/// What each engine skips while the folder is not trusted, and the Trust this folder button.
struct CustomizationsTrustSection: View {
    let model: CustomizationsModel
    let summary: CustomizationTrustSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(14)) {
            HStack(alignment: .top, spacing: theme.z(10)) {
                Image(systemName: summary.trusted ? "checkmark.shield" : "lock.shield")
                    .font(theme.font(size: 15, weight: .medium))
                    .foregroundStyle(summary.trusted ? theme.success : theme.warning)
                    .frame(width: theme.z(18))
                VStack(alignment: .leading, spacing: theme.z(6)) {
                    Text(summary.trusted ? "This folder is trusted" : "This folder is not trusted")
                        .font(theme.font(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(message)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !summary.trusted, summary.canBeTrusted {
                        Button("Trust this folder") { model.trustFolder() }
                            .buttonStyle(PrimaryButtonStyle())
                            .help("Trust \(summary.folder) so agents load its own files")
                            .padding(.top, theme.z(4))
                    }
                    if let error = model.trustError {
                        Text(error)
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(theme.z(14))
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border, lineWidth: 1))

            HStack(alignment: .top, spacing: theme.z(12)) {
                ForEach(summary.notes) { note in
                    engineNote(note)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var message: String {
        if summary.trusted {
            return "Agents load this folder's own settings, instructions, hooks and MCP servers. Remove it under General, Trusted folders."
        }
        if !summary.canBeTrusted {
            return "The home folder and the folders above it cannot be trusted, since that would trust every project. Choose a project folder."
        }
        return summary.skipsAnything
            ? "Until you trust it, agents run here without the folder's own files listed below."
            : "This folder has no agent files of its own, so nothing is skipped. Gemini still only starts in trusted folders."
    }

    private func engineNote(_ note: CustomizationTrustSummary.EngineNote) -> some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text(note.engine.displayName)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(note.headline)
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(summary.trusted ? theme.textPrimary : theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text(note.detail)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !note.skipped.isEmpty {
                Text("Skipped now")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, theme.z(4))
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    ForEach(note.skipped, id: \.self) { path in
                        Text(path)
                            .font(theme.font(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
            }
        }
        .padding(theme.z(12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
