import SwiftUI
import AppKit
import EnsembleKit

/// "Import Claude sessions": every folder with Claude sessions from the claude CLI and the Claude desktop app, its
/// session count and date range, all ticked except missing folders; the desktop app's environments with what maps;
/// and an unticked "Trust these folders".
struct ClaudeImportSheet: View {
    @Bindable var model: ClaudeImportModel
    var onClose: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var middleHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, theme.z(22))
                .padding(.top, theme.z(20))
                .padding(.bottom, theme.z(14))
            switch model.phase {
            case .scanning:
                scanning
            case .ready, .importing:
                if let scan = model.scan, !scan.folders.isEmpty {
                    content(scan)
                } else {
                    nothingFound
                }
            case .finished(let result):
                finished(result)
            }
        }
        .frame(width: theme.z(640))
        .background(theme.background)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.z(5)) {
            Text("Import Claude sessions")
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("From the claude CLI and the Claude desktop app. Sessions resume where they left off, and their files stay where they are.")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scanning: some View {
        VStack(spacing: theme.z(10)) {
            Spinner(size: 16)
            Text("Reading Claude sessions")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: theme.z(220))
        .overlay(alignment: .bottomTrailing) {
            Button("Cancel", action: onClose)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, theme.z(22))
                .padding(.vertical, theme.z(18))
        }
    }

    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: theme.z(16)) {
            Text("No Claude sessions were found in the claude CLI's projects folder.")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, theme.z(22))
        .padding(.bottom, theme.z(20))
    }

    // MARK: Folders

    private func content(_ scan: ClaudeImportScan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            selectionBar
                .padding(.horizontal, theme.z(22))
                .padding(.bottom, theme.z(8))
            // Everything between the selection bar and the buttons scrolls when the screen is too short for it
            // (a small screen or a large zoom), so the buttons always stay in view.
            AdaptiveScroll {
                middle(scan)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { middleHeight = $0 }
            }
            .frame(height: isSnapshot ? nil : max(theme.z(150), min(middleHeight, maxMiddleHeight)))
            HLine()
            footer
                .padding(.horizontal, theme.z(22))
                .padding(.vertical, theme.z(14))
        }
        .disabled(model.phase == .importing)
    }

    private func middle(_ scan: ClaudeImportScan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            folderList(scan)
            if !scan.environments.isEmpty {
                environments(scan.environments)
                    .padding(.top, theme.z(16))
            }
            if model.showsArchiveOption {
                archiveBox
                    .padding(.top, theme.z(16))
            }
            trustBox
                .padding(.top, theme.z(model.showsArchiveOption ? 12 : 16))
            notes(scan)
                .padding(.top, theme.z(12))
        }
        .padding(.horizontal, theme.z(22))
        .padding(.bottom, theme.z(16))
    }

    /// The screen's height less the header, selection bar, buttons and some margin.
    private var maxMiddleHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return screen - theme.z(190) - 60
    }

    private var selectionBar: some View {
        HStack(spacing: theme.z(12)) {
            Text(selectionSummary)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
            Spacer()
            linkButton("Select all", action: model.selectAll)
                .disabled(model.selected.count == model.selectableFolders.count)
            linkButton("None", action: model.selectNone)
                .disabled(model.selected.isEmpty)
        }
    }

    private var selectionSummary: String {
        let folders = model.selectedFolders.count
        let sessions = model.selectedSessions.count
        return "\(folders) of \(model.selectableFolders.count) folders, \(Self.count(sessions, "session")) selected"
    }

    private func folderList(_ scan: ClaudeImportScan) -> some View {
        AdaptiveScroll {
            LazyVStack(spacing: 0) {
                ForEach(Array(scan.folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 { HLine().padding(.leading, theme.z(40)) }
                    FolderRow(folder: folder, isOn: model.selected.contains(folder.path)) { model.toggle(folder) }
                }
            }
        }
        .frame(height: theme.z(min(CGFloat(scan.folders.count), 4.5) * FolderRow.height))
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.border))
    }

    // MARK: Environments

    private func environments(_ list: [ClaudeImportEnvironment]) -> some View {
        let local = list.filter { $0.kind == .local }
        let unsupported = list.filter { !$0.isSupported }
        let withoutSessions = local.filter { environment in !model.folders.contains { $0.path == environment.folder } }
        return VStack(alignment: .leading, spacing: theme.z(6)) {
            sectionLabel("Environments")
            VStack(spacing: 0) {
                if !local.isEmpty {
                    LocalEnvironmentsRow(environments: local, withoutSessions: withoutSessions)
                }
                ForEach(Array(unsupported.enumerated()), id: \.element.id) { index, environment in
                    if index > 0 || !local.isEmpty { HLine().padding(.leading, theme.z(36)) }
                    EnvironmentRow(environment: environment)
                }
            }
            .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.panel))
            .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.border))
            if !unsupported.isEmpty {
                Text("Ensemble runs agents in folders on this Mac, so SSH and cloud environments are not imported.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Trust

    private var trustBox: some View {
        HStack(alignment: .top, spacing: theme.z(10)) {
            ImportCheckbox(isOn: model.trustFolders) { model.trustFolders.toggle() }
                .disabled(model.trustCandidates.isEmpty)
                .padding(.top, theme.z(1))
            VStack(alignment: .leading, spacing: theme.z(4)) {
                Button { model.trustFolders.toggle() } label: {
                    Text("Trust these folders")
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(model.trustCandidates.isEmpty)
                Text(trustExplanation)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.trustedInCLI.isEmpty {
                    Text("Trusted in the claude CLI: " + Self.nameList(model.trustedInCLI.map { Format.folderName($0.path) }) + ".")
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Archive

    private var archiveBox: some View {
        let count = model.outsideDesktopAppCount
        return HStack(alignment: .top, spacing: theme.z(10)) {
            ImportCheckbox(isOn: model.archiveOutsideDesktopApp && count > 0) { model.archiveOutsideDesktopApp.toggle() }
                .disabled(count == 0)
                .padding(.top, theme.z(1))
            VStack(alignment: .leading, spacing: theme.z(4)) {
                HStack(spacing: theme.z(7)) {
                    Button { model.archiveOutsideDesktopApp.toggle() } label: {
                        Text("Archive sessions started outside the desktop app")
                            .font(theme.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                    CountBadge(count, color: theme.textTertiary.opacity(count == 0 ? 0.5 : 1))
                        .accessibilityLabel(Self.count(count, "session"))
                }
                Text("Terminal and headless claude -p sessions come in archived and stay out of the sidebar. Search still finds and opens them.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trustExplanation: String {
        let count = model.trustCandidates.count
        if count == 0 { return "The selected folders are already trusted, or none are selected." }
        let which = count == 1 ? "the selected folder" : "the \(count) selected folders"
        return "Trusted folders load their own settings, hooks and MCP servers when an agent starts there. Ticking this trusts \(which)."
    }

    // MARK: Notes

    private struct Note: Identifiable {
        var icon: String
        var text: String
        var warn = false
        var id: String { text }
    }

    private func noteLines(_ scan: ClaudeImportScan) -> [Note] {
        let sessions = model.selectedSessions
        var lines = [Note(icon: "lock.shield", text: "Imported sessions start in \(model.permissionMode.label), Ensemble's default.")]
        let archived = sessions.filter(\.archived).count
        if archived > 0 {
            lines.append(Note(icon: "archivebox", text: "\(Self.count(archived, "archived session")) \(archived == 1 ? "stays" : "stay") archived."))
        }
        let open = sessions.filter(\.recentlyWritten).count
        if open > 0 {
            let pronoun = open == 1 ? "it" : "them"
            lines.append(Note(icon: "exclamationmark.triangle",
                              text: "\(Self.count(open, "session")) changed in the last few minutes and may still be open in another app. Close \(pronoun) there before continuing here.",
                              warn: true))
        }
        let missing = model.selectedFolders.filter { !$0.exists }.reduce(0) { $0 + $1.newSessions.count }
        if missing > 0 {
            lines.append(Note(icon: "folder.badge.questionmark",
                              text: "\(Self.count(missing, "session")) in missing folders can be read but not resumed until the folder is back.",
                              warn: true))
        }
        let left = scan.skipped.deletedInDesktopApp + scan.skipped.replacedByNewerConversation
        if left > 0 {
            lines.append(Note(icon: "minus.circle",
                              text: "\(Self.count(left, "session")) deleted or replaced in the desktop app \(left == 1 ? "is" : "are") left out."))
        }
        return lines
    }

    private func notes(_ scan: ClaudeImportScan) -> some View {
        VStack(alignment: .leading, spacing: theme.z(5)) {
            ForEach(noteLines(scan)) { line in
                HStack(alignment: .firstTextBaseline, spacing: theme.z(7)) {
                    Image(systemName: line.icon)
                        .font(.system(size: theme.z(10.5)))
                        .foregroundStyle(line.warn ? theme.warning : theme.textTertiary)
                        .frame(width: theme.z(14))
                    Text(line.text)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: theme.z(8)) {
            if model.phase == .importing {
                Spinner(size: 12)
                Text("Importing")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(importLabel) { Task { await model.runImport() } }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedSessions.isEmpty || model.phase != .ready)
        }
    }

    private var importLabel: String {
        let count = model.selectedSessions.count
        return count == 0 ? "Import" : "Import \(Self.count(count, "session"))"
    }

    // MARK: Finished

    private func finished(_ result: ClaudeImportResult) -> some View {
        VStack(alignment: .leading, spacing: theme.z(14)) {
            HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: theme.z(13)))
                    .foregroundStyle(theme.success)
                VStack(alignment: .leading, spacing: theme.z(4)) {
                    Text(result.imported == 0
                         ? "Nothing new to import."
                         : "Imported \(Self.count(result.imported, "session")) in \(Self.count(result.folders, "folder")).")
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    if result.alreadyThere > 0 {
                        Text("\(Self.count(result.alreadyThere, "session")) Ensemble already had \(result.alreadyThere == 1 ? "was" : "were") left as \(result.alreadyThere == 1 ? "it was" : "they were").")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    if model.archivedOutside > 0 {
                        Text("Archived \(Self.count(model.archivedOutside, "session")) started outside the desktop app. Search finds them.")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    if model.pinned > 0 {
                        Text("Pinned \(Self.count(model.pinned, "starred session")).")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    if !result.trusted.isEmpty {
                        Text("Trusted \(Self.count(result.trusted.count, "folder")).")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            if !result.notTrusted.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(4)) {
                    Text("Not trusted:")
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    ForEach(result.notTrusted.keys.sorted(), id: \.self) { path in
                        Text((result.notTrusted[path] ?? path).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, theme.z(23))
            }
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, theme.z(22))
        .padding(.bottom, theme.z(20))
    }

    // MARK: Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(ImportLinkButtonStyle())
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// "a, b and c", or "a, b, c and 9 more" past four names.
    static func nameList(_ names: [String]) -> String {
        let shown = names.prefix(4)
        let rest = names.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        guard shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + (shown.last ?? "")
    }
}

// MARK: - Rows

private struct FolderRow: View {
    static let height: CGFloat = 46
    let folder: ClaudeImportFolder
    let isOn: Bool
    let toggle: () -> Void
    @Environment(\.theme) private var theme

    private var enabled: Bool { !folder.newSessions.isEmpty }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: theme.z(10)) {
                ImportCheckbox(isOn: isOn && enabled, action: toggle)
                    .allowsHitTesting(false)
                Image(systemName: folder.exists ? "folder" : "folder.badge.questionmark")
                    .font(.system(size: theme.z(13)))
                    .foregroundStyle(folder.exists ? theme.textSecondary : theme.warning)
                    .frame(width: theme.z(18))
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    HStack(spacing: theme.z(6)) {
                        Text(Format.folderName(folder.path))
                            .font(theme.font(size: 13, weight: .medium))
                            .foregroundStyle(folder.exists && enabled ? theme.textPrimary : theme.textSecondary)
                            .lineLimit(1)
                        if !folder.exists { tag("Missing", color: theme.warning) }
                    }
                    Text(Format.abbreviatedPath(folder.path))
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: theme.z(12))
                VStack(alignment: .trailing, spacing: theme.z(2)) {
                    Text(countText)
                        .font(theme.font(size: 12))
                        .foregroundStyle(enabled ? theme.textSecondary : theme.textTertiary)
                        .monospacedDigit()
                    if let range = ClaudeImportDates.range(folder.earliest, folder.latest) {
                        Text(range)
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, theme.z(12))
            .frame(height: theme.z(Self.height))
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(cornerRadius: 0))
        .disabled(!enabled)
        .help(folder.path)
        .accessibilityLabel("\(Format.folderName(folder.path)), \(countText)\(folder.exists ? "" : ", missing")")
        .accessibilityAddTraits(isOn && enabled ? [.isSelected] : [])
    }

    private var countText: String {
        let total = folder.sessions.count
        let new = folder.newSessions.count
        if new == 0 { return "All \(ClaudeImportSheet.count(total, "session")) imported" }
        if new < total { return "\(new) new, \(total - new) imported" }
        return ClaudeImportSheet.count(total, "session")
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(theme.font(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, theme.z(5))
            .frame(height: theme.z(16))
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// The desktop app's local environments in one row: their folders come in with their sessions.
private struct LocalEnvironmentsRow: View {
    let environments: [ClaudeImportEnvironment]
    let withoutSessions: [ClaudeImportEnvironment]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(10)) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: theme.z(12)))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(16))
            VStack(alignment: .leading, spacing: theme.z(3)) {
                HStack(spacing: theme.z(6)) {
                    Text("Local")
                        .font(theme.font(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(ClaudeImportSheet.nameList(environments.map(\.name)))
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(9))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var text = "Their folders come in with their sessions. Model and effort settings are not imported."
        if !withoutSessions.isEmpty {
            text += " No sessions in " + ClaudeImportSheet.nameList(withoutSessions.map(\.name)) + "."
        }
        return text
    }
}

/// An SSH, cloud or unknown environment, which Ensemble cannot import.
private struct EnvironmentRow: View {
    let environment: ClaudeImportEnvironment
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: icon)
                .font(.system(size: theme.z(12)))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(16))
                .padding(.trailing, theme.z(2))
            Text(environment.name)
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(kindLabel)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            if let host = environment.host {
                Text(host)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: theme.z(12))
            Text("Not supported yet")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, theme.z(12))
        .frame(height: theme.z(34))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch environment.kind {
        case .local: "laptopcomputer"
        case .ssh: "network"
        case .cloud: "cloud"
        case .other: "questionmark.square.dashed"
        }
    }

    private var kindLabel: String {
        switch environment.kind {
        case .local: "Local folder"
        case .ssh: "SSH host"
        case .cloud: "Cloud"
        case .other: environment.rawKind
        }
    }
}

/// A square checkbox drawn in SwiftUI (renders in snapshots, matches the theme in both modes).
struct ImportCheckbox: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.z(4), style: .continuous)
                    .fill(isOn ? theme.accent : theme.elevated)
                RoundedRectangle(cornerRadius: theme.z(4), style: .continuous)
                    .strokeBorder(isOn ? theme.accent : theme.border, lineWidth: 1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: theme.z(9), weight: .bold))
                        .foregroundStyle(theme.onAccent)
                }
            }
            .frame(width: theme.z(15), height: theme.z(15))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Text button in the accent colour ("Select all", "None").
private struct ImportLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? theme.accent : theme.textTertiary)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// "Oct 3 to Nov 18", with the year when it is not this year.
enum ClaudeImportDates {
    static func range(_ start: Date?, _ end: Date?, now: Date = Date()) -> String? {
        guard let start, let end else { return nil }
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: now)
        func text(_ date: Date) -> String {
            let style = calendar.component(.year, from: date) == thisYear
                ? Date.FormatStyle().month(.abbreviated).day()
                : Date.FormatStyle().month(.abbreviated).day().year()
            return date.formatted(style)
        }
        if calendar.isDate(start, inSameDayAs: end) { return text(end) }
        return "\(text(start)) to \(text(end))"
    }
}
