import SwiftUI
import EnsembleKit

// Small controls for the scheduled task editor, drawn in SwiftUI so they follow the window zoom and render in snapshots.

/// A field-like button that opens a popover: icon, value, chevron.
struct ScheduleChip<Popover: View>: View {
    let symbol: String?
    let text: String
    var tint: Color?
    var monospaced = false
    @ViewBuilder let popover: (_ dismiss: @escaping () -> Void) -> Popover
    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: theme.z(7)) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(tint ?? theme.textSecondary)
                }
                Text(text)
                    .font(monospaced ? theme.font(size: 12.5, design: .monospaced) : theme.font(size: 13))
                    .foregroundStyle(tint ?? theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, theme.z(10))
            .frame(height: theme.z(30))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering || open ? theme.elevatedHover : theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popover({ open = false })
                .ensembleTheme()
        }
    }
}

/// One choice in a popover list: title, optional detail, a check on the current one.
struct ScheduleChoiceRow: View {
    let title: String
    var detail: String?
    var symbol: String?
    var selected = false
    var tint: Color?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: theme.z(10)) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(tint ?? theme.textSecondary)
                        .frame(width: theme.z(18), height: theme.z(18))
                }
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    Text(title)
                        .font(theme.font(size: 13, weight: detail == nil ? .regular : .medium))
                        .foregroundStyle(tint ?? theme.textPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: theme.z(8))
                if selected {
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(height: theme.z(18))
                }
            }
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(6))
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A popover's list of choices.
struct ScheduleChoiceList<Content: View>: View {
    var width: CGFloat = 300
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) { content }
            .padding(theme.z(6))
            .frame(width: theme.z(width), alignment: .leading)
            .background(theme.popover)
    }
}

/// Segmented buttons ("Hourly", "Daily", ...), one selected.
struct ScheduleSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(2)) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(theme.font(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: theme.z(26))
                        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                            .fill(selected ? theme.elevatedHover : .clear)
                            .shadow(color: selected ? .black.opacity(theme.isDark ? 0.3 : 0.08) : .clear, radius: theme.z(1), y: theme.z(0.5)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(theme.z(2))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.track.opacity(theme.isDark ? 0.7 : 0.6)))
    }
}

/// A time of day: a chip with an hour and minute grid in its popover (minutes in steps of 5; a custom cron takes any).
struct ScheduleTimeChip: View {
    @Binding var hour: Int
    @Binding var minute: Int
    @Environment(\.theme) private var theme

    var body: some View {
        ScheduleChip(symbol: "clock", text: ScheduleTrigger.time(hour: hour, minute: minute, calendar: .current)) { dismiss in
            VStack(alignment: .leading, spacing: theme.z(10)) {
                ScheduleGridLabel(text: "Hour")
                grid(Array(0..<24), columns: 6, selected: hour, label: Self.hourLabel) { hour = $0 }
                ScheduleGridLabel(text: "Minute")
                grid(Array(stride(from: 0, to: 60, by: 5)), columns: 6, selected: minute, label: { ":" + Self.twoDigits($0) }) {
                    minute = $0
                    dismiss()
                }
            }
            .padding(theme.z(12))
            .frame(width: theme.z(300))
            .background(theme.popover)
        }
    }

    private func grid(_ values: [Int], columns: Int, selected: Int, label: @escaping (Int) -> String,
                      pick: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.z(4)), count: columns), spacing: theme.z(4)) {
            ForEach(values, id: \.self) { value in
                ScheduleGridButton(text: label(value), selected: value == selected) { pick(value) }
            }
        }
    }

    /// "9 AM" or "09", as the locale writes hours.
    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = hour
        guard let date = Calendar.current.date(from: components) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

    static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}

/// The minute of each hour, for the hourly trigger.
struct ScheduleMinuteChip: View {
    @Binding var minute: Int
    @Environment(\.theme) private var theme

    var body: some View {
        ScheduleChip(symbol: "clock", text: ":" + ScheduleTimeChip.twoDigits(minute)) { dismiss in
            VStack(alignment: .leading, spacing: theme.z(10)) {
                ScheduleGridLabel(text: "Minute past the hour")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.z(4)), count: 6), spacing: theme.z(4)) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { value in
                        ScheduleGridButton(text: ":" + ScheduleTimeChip.twoDigits(value), selected: value == minute) {
                            minute = value
                            dismiss()
                        }
                    }
                }
            }
            .padding(theme.z(12))
            .frame(width: theme.z(280))
            .background(theme.popover)
        }
    }
}

struct ScheduleGridLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 11, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
    }
}

struct ScheduleGridButton: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(theme.font(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: theme.z(26))
                .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                    .fill(selected ? theme.accent : (hovering ? theme.hover : theme.elevated)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A multi-line text box; a static copy in snapshots.
struct SchedulePromptEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 92
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSnapshot {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(8))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, theme.z(5))
                    .padding(.vertical, theme.z(6))
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, theme.z(10))
                        .padding(.vertical, theme.z(8))
                        .allowsHitTesting(false)
                }
            }
        }
        .font(theme.font(size: 13))
        .frame(minHeight: theme.z(minHeight), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
            .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
    }
}
