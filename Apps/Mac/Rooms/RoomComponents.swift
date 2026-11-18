import SwiftUI
import AppKit
import EnsembleKit

// MARK: - Presentation of room types

extension RoomMode {
    var symbolName: String {
        switch self {
        case .solo: "person"
        case .team: "person.3"
        case .debate: "bubble.left.and.bubble.right"
        case .roundTable: "circle.hexagongrid"
        }
    }

    /// One line on how the mode works (new room sheet).
    var explanation: String {
        switch self {
        case .team: "The lead splits the work, everyone builds at once, and each piece is reviewed by another agent."
        case .debate: "Agents argue a question in rounds, then the judge writes the verdict. No file edits."
        case .roundTable: "Agents agree on one plan in turns, then one builds while the others review each step."
        case .solo: "One agent, like a normal chat."
        }
    }

    /// Display order in the new room sheet.
    static let sheetOrder: [RoomMode] = [.team, .debate, .roundTable, .solo]
}

extension AgentActivity {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waitingForPermission: "Waiting for permission"
        case .capped: "Capped"
        }
    }
}

extension AssignmentStatus {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .pending: theme.textTertiary
        case .working: theme.accent
        case .inReview: theme.contextBlue
        case .changesRequested: theme.warning
        case .approved: theme.success
        case .merged: theme.success
        case .dropped: theme.danger
        }
    }
}

extension BoardMessageKind {
    /// Tag shown next to the sender. `nil` for plain chat.
    var tag: String? {
        switch self {
        case .chat, .notice: nil
        case .plan: "Plan"
        case .assignment: "Assignment"
        case .update: "Update"
        case .question: "Question"
        case .review: "Review"
        case .argument: "Argument"
        case .verdict: "Verdict"
        }
    }
}

enum RoomPalette {
    /// Agent colours in the order new agents get them.
    static let colors: [String] = ["#A78BFA", "#34D399", "#60A5FA", "#FBBF24", "#F472B6", "#FB923C", "#22D3EE", "#F87171"]

    static func next(after used: [String]) -> String {
        colors.first { !used.contains($0) } ?? colors[used.count % colors.count]
    }
}

/// Short display name for a model ("Opus 5.5" for "Claude Opus 5.5").
func shortModelName(_ ref: ModelRef, models: [ModelInfo] = []) -> String {
    let name = models.first { $0.ref.providerID == ref.providerID && $0.ref.id == ref.id }?.name ?? ref.id
    return name.hasPrefix("Claude ") ? String(name.dropFirst(7)) : name
}

// MARK: - Small views

/// An agent's colour dot. `size` is in points at 100% zoom.
struct AgentDot: View {
    let hex: String
    var size: CGFloat = 8
    @Environment(\.theme) private var theme
    var body: some View {
        Circle()
            .fill(Color(hexString: hex))
            .frame(width: theme.z(size), height: theme.z(size))
    }
}

/// Overlapping agent colour dots (sidebar rows, room lists).
struct AgentDots: View {
    let colors: [String]
    var size: CGFloat = 7
    var ring: Color
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: theme.z(-2)) {
            ForEach(Array(colors.prefix(6).enumerated()), id: \.offset) { _, hex in
                Circle()
                    .fill(Color(hexString: hex))
                    .frame(width: theme.z(size), height: theme.z(size))
                    .overlay(Circle().stroke(ring, lineWidth: 1.5))
            }
        }
    }
}

/// Small rounded tag ("Plan", "Lead", "Round 2").
struct RoomTag: View {
    let text: String
    var color: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 10.5, weight: .semibold))
            .foregroundStyle(color ?? theme.textSecondary)
            .padding(.horizontal, theme.z(6))
            .frame(height: theme.z(17))
            .background(RoundedRectangle(cornerRadius: theme.z(4.5), style: .continuous).fill((color ?? theme.textSecondary).opacity(0.13)))
    }
}

/// Section title in the room side panel and the new room sheet.
struct RoomSectionTitle: View {
    let text: String
    var trailing: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(text)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(theme.font(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }
}

/// A chip that opens a list of choices in a popover (pure SwiftUI, so it also draws in snapshots).
struct ChoiceChip<Value: Hashable>: View {
    let title: String
    var symbol: String?
    var dotHex: String?
    var tint: Color?
    var bordered = true
    var maxWidth: CGFloat?
    let options: [(value: Value, title: String, detail: String?, dotHex: String?, enabled: Bool)]
    let selection: Value
    let onSelect: (Value) -> Void

    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: theme.z(6)) {
                if let dotHex { AgentDot(hex: dotHex, size: 8) }
                if let symbol { Image(systemName: symbol).font(theme.font(size: 11.5)) }
                Text(title)
                    .font(theme.font(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(theme.font(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(tint ?? (hovering ? theme.textPrimary : theme.textSecondary))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(28))
            .background(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .fill(bordered ? (hovering ? theme.elevatedHover : theme.elevated) : (hovering ? theme.hover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .strokeBorder(bordered ? theme.border : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ChoiceList(options: options, selection: selection) { value in
                open = false
                onSelect(value)
            }
            .ensembleTheme()
        }
    }
}

struct ChoiceList<Value: Hashable>: View {
    let options: [(value: Value, title: String, detail: String?, dotHex: String?, enabled: Bool)]
    let selection: Value
    let onSelect: (Value) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.z(1)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button { onSelect(option.value) } label: {
                        HStack(spacing: theme.z(8)) {
                            if let dot = option.dotHex { AgentDot(hex: dot, size: 9) }
                            VStack(alignment: .leading, spacing: theme.z(1)) {
                                Text(option.title)
                                    .font(theme.font(size: 13))
                                    .foregroundStyle(option.enabled ? theme.textPrimary : theme.textTertiary)
                                if let detail = option.detail {
                                    Text(detail)
                                        .font(theme.font(size: 11.5))
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                            Spacer(minLength: 12)
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .font(theme.font(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .padding(.horizontal, theme.z(10))
                        .padding(.vertical, theme.z(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(RowButtonStyle(cornerRadius: theme.z(6)))
                    .disabled(!option.enabled)
                }
            }
            .padding(theme.z(5))
        }
        .frame(minWidth: theme.z(220), maxHeight: theme.z(360))
        .fixedSize(horizontal: true, vertical: false)
        .background(theme.popover)
    }
}

/// Multi-line text box. Draws a static copy in snapshots (text editors are platform views).
struct RoomTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 80
    var maxHeight: CGFloat = 220
    var monospaced = false
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSnapshot {
                Text(text.isEmpty ? placeholder : text)
                    .font(font)
                    .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(8))
            } else {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, theme.z(10))
                        .padding(.vertical, theme.z(8))
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(font)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, theme.z(5))
                    .padding(.vertical, theme.z(8))
                    .frame(minHeight: minHeight, maxHeight: maxHeight)
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border))
    }

    private var font: Font { monospaced ? theme.font(size: 12.5, design: .monospaced) : theme.font(size: 13) }
}

/// Header button in the room view ("Pause", "Stop", "Take over").
struct RoomHeaderButton: View {
    let title: String
    let symbol: String
    var tint: Color?
    /// Icon only, with the title in the tooltip (narrow windows).
    var compact = false
    /// Tooltip; defaults to the title.
    var tooltip: String?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(5)) {
                Image(systemName: symbol).font(theme.font(size: 11, weight: .medium))
                if !compact { Text(title).font(theme.font(size: 12.5, weight: .medium)) }
            }
            .foregroundStyle(tint ?? theme.textPrimary)
            .padding(.horizontal, theme.z(10))
            .frame(height: theme.z(26))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering ? theme.elevatedHover : theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip ?? title)
        .accessibilityLabel(title)
    }
}

/// Card frame used by decision cards and the verdict.
struct RoomCard<Content: View>: View {
    var accent: Color?
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) { content }
            .padding(theme.z(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .strokeBorder((accent ?? theme.border).opacity(accent == nil ? 1 : 0.5), lineWidth: 1)
            )
    }
}

/// Opens a folder in Finder.
@MainActor func revealInFinder(_ path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
}
