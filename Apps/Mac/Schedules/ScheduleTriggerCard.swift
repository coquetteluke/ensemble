import SwiftUI
import EnsembleKit

/// The trigger card: Hourly, Daily, Weekdays, Weekly, Monthly or Custom (cron), the choices for that kind, and the next three
/// times it runs (or why it cannot).
struct ScheduleTriggerCard: View {
    @Binding var trigger: ScheduleTrigger
    /// Snapshots pass a fixed time for the preview of the next runs.
    var now: Date?
    @Environment(\.theme) private var theme
    @State private var cronText = ""

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(12)) {
            ScheduleSegmented(options: ScheduleTrigger.Kind.allCases.map { ($0, $0.label) }, selection: kindBinding)
            detail
            preview
        }
        .padding(theme.z(12))
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.panel))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.border))
        .onAppear { if case .custom(let cron) = trigger { cronText = cron } }
    }

    // MARK: Kind

    private var kindBinding: Binding<ScheduleTrigger.Kind> {
        Binding(get: { trigger.kind }, set: { kind in
            let converted = trigger.converted(to: kind, calendar: calendar)
            if case .custom(let cron) = converted { cronText = cron }
            trigger = converted
        })
    }

    @ViewBuilder private var detail: some View {
        switch trigger {
        case .hourly(let minute):
            row("Every hour at") {
                ScheduleMinuteChip(minute: Binding(get: { minute }, set: { trigger = .hourly(minute: $0) }))
            }
        case .daily(let hour, let minute):
            row("Every day at") { timeChip(hour, minute) { .daily(hour: $0, minute: $1) } }
        case .weekdays(let hour, let minute):
            row("Monday to Friday at") { timeChip(hour, minute) { .weekdays(hour: $0, minute: $1) } }
        case .weekly(let days, let hour, let minute):
            VStack(alignment: .leading, spacing: theme.z(10)) {
                HStack(spacing: theme.z(5)) {
                    ForEach(ScheduleWeekday.ordered(calendar), id: \.self) { day in
                        dayButton(day, selected: days.contains(day)) {
                            var updated = days
                            if updated.contains(day) { updated.remove(day) } else { updated.insert(day) }
                            trigger = .weekly(days: updated, hour: hour, minute: minute)
                        }
                    }
                }
                row("At") { timeChip(hour, minute) { .weekly(days: days, hour: $0, minute: $1) } }
            }
        case .monthly(let day, let hour, let minute):
            row("Every month on the") {
                ScheduleMonthDayChip(day: Binding(get: { day }, set: { trigger = .monthly(day: $0, hour: hour, minute: minute) }))
                Text("at")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                timeChip(hour, minute) { .monthly(day: day, hour: $0, minute: $1) }
            }
        case .custom:
            VStack(alignment: .leading, spacing: theme.z(6)) {
                InputField("0 9 * * 1-5", text: Binding(get: { cronText }, set: { text in
                    cronText = text
                    trigger = .custom(cron: text)
                }), monospaced: true, height: 30)
                Text("Minute, hour, day of month, month, day of week. For example 0 9 * * 1-5 is 9:00 on weekdays.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: theme.z(10)) {
            Text(label)
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textSecondary)
            content()
            Spacer(minLength: 0)
        }
    }

    private func timeChip(_ hour: Int, _ minute: Int, make: @escaping (Int, Int) -> ScheduleTrigger) -> some View {
        ScheduleTimeChip(hour: Binding(get: { hour }, set: { trigger = make($0, minute) }),
                         minute: Binding(get: { minute }, set: { trigger = make(hour, $0) }))
    }

    private func dayButton(_ day: ScheduleWeekday, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(day.shortName(calendar))
                .font(theme.font(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.onAccent : theme.textSecondary)
                .frame(width: theme.z(44), height: theme.z(28))
                .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(selected ? theme.accent : theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(selected ? .clear : theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.name(calendar))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        let reference = now ?? Date()
        if let error = trigger.validationError(calendar: calendar, now: reference) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let fires = trigger.nextFires(after: reference, count: 3, calendar: calendar)
            HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                Text("Next runs")
                    .foregroundStyle(theme.textTertiary)
                Text(fires.map { ScheduleFormat.when($0, now: reference, calendar: calendar) }.joined(separator: ",  "))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .font(theme.font(size: 12))
        }
    }
}
