import SwiftUI
import EnsembleKit

/// The context panel's Safety check section: what the safety check for Auto decided in this session (and its subagents),
/// newest first, with the reason on hover, and the classifier's estimated tokens. Shown once there is a decision.
struct SafetyCheckPanelSection: View {
    let store: SessionStore
    let session: SessionModel
    @Environment(\.theme) private var theme
    @State private var showAll = false

    /// Rows shown before "Show all".
    static let rowLimit = 6

    var body: some View {
        let decisions = store.safetyCheckDecisions(for: session.id)
        let usage = store.safetyCheckUsage(for: session.id)
        let allowed = decisions.filter(\.allowed).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text("Safety check")
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(8))
                Text("\(allowed) allowed, \(decisions.count - allowed) asked")
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(theme.font(size: 13))
            .frame(height: theme.z(30))

            ForEach(showAll ? decisions : Array(decisions.prefix(Self.rowLimit))) { decision in
                SafetyCheckDecisionRow(decision: decision)
            }
            if decisions.count > Self.rowLimit {
                Button(showAll ? "Show fewer" : "Show all \(decisions.count)") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .frame(height: theme.z(24))
            }
            if usage.checks > 0 {
                Text(Self.usageLine(usage))
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, theme.z(4))
                    .help("Safety check usage in this session, estimated from the text sent and received")
            }
        }
        .padding(.top, theme.z(8))
        .padding(.bottom, theme.z(8))
    }

    /// "3 model checks, about 2.4k tokens, $0.0012".
    static func usageLine(_ usage: SafetyCheckUsage) -> String {
        var line = "\(usage.checks) model \(usage.checks == 1 ? "check" : "checks"), about \(Format.tokens(usage.totalTokens)) tokens"
        if usage.costUSD > 0 { line += ", \(Format.usd(usage.costUSD))" }
        return line
    }
}

/// One decision: what was checked, and Allowed or Asked; the reason shows on hover.
struct SafetyCheckDecisionRow: View {
    let decision: SafetyCheckDecision
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(11)) {
            Image(systemName: decision.allowed ? "checkmark.shield" : "hand.raised")
                .font(theme.font(size: 11))
                .foregroundStyle(decision.allowed ? theme.success : theme.textTertiary)
                .frame(width: theme.z(18))
            Text(decision.subject.replacingOccurrences(of: "\n", with: " "))
                .font(decision.action == "shell" ? theme.font(size: 12, design: .monospaced) : theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: theme.z(6))
            Text(decision.allowed ? "Allowed" : "Asked")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: theme.z(26))
        .contentShape(Rectangle())
        .help(Self.help(decision))
        .accessibilityElement(children: .combine)
    }

    static func help(_ decision: SafetyCheckDecision) -> String {
        let verdict = decision.allowed ? "Allowed" : "Asked you"
        let source = switch decision.basis {
        case .rule: "a fixed rule"
        case .model: decision.model.map { "the model \($0.description)" } ?? "the model"
        case .cache: "an earlier answer in this session"
        case .failed: "the check could not decide"
        }
        return "\(verdict) (\(source)): \(decision.reason)"
    }
}
