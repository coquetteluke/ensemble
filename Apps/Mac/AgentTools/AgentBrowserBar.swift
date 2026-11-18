import SwiftUI
import EnsembleKit

/// The browser pane's strip while an agent uses the page: what it is doing, with Take over and Stop; "You have the
/// browser" with Hand back after Take over or on a sign-in page; and the permission card for a call that waits.
struct AgentBrowserBarHost: View {
    let session: SessionModel
    var center: AgentToolsCenter = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        if let coordinator = center.coordinator {
            let state = coordinator.browserState(session.id)
            let request = coordinator.permissionRequest(for: session.id)
            if Self.showsBar(state: state, request: request, working: session.isWorking) {
                VStack(spacing: 0) {
                    AgentBrowserBar(state: state, waiting: request != nil,
                                    onStop: { coordinator.stop(session.id) },
                                    onTakeOver: { coordinator.takeOver(session.id) },
                                    onHandBack: { coordinator.handBack(session.id) })
                    if let request {
                        HLine()
                        AgentBrowserPermissionCard(request: request) { coordinator.answer(request.id, $0) }
                            .padding(theme.z(10))
                    }
                    HLine()
                }
            }
        }
    }

    /// While a card waits, while the user holds the browser, or while the agent's turn that used it runs.
    static func showsBar(state: AgentBrowserState, request: BrowserPermissionRequest?, working: Bool) -> Bool {
        if request != nil || state.userHasControl || state.running { return true }
        if case .stopped? = state.pause { return false }
        return state.lastActivity != nil && working
    }
}

/// The pending browser permission card above the composer, so the prompt is seen with the browser pane closed.
struct AgentBrowserPermissionHost: View {
    let session: SessionModel
    var center: AgentToolsCenter = .shared

    var body: some View {
        if let coordinator = center.coordinator, let request = coordinator.permissionRequest(for: session.id) {
            AgentBrowserPermissionCard(request: request) { coordinator.answer(request.id, $0) }
        }
    }
}

/// "Agent is using the browser" with the newest action, Take over and Stop; or who holds the browser now.
struct AgentBrowserBar: View {
    let state: AgentBrowserState
    let waiting: Bool
    let onStop: () -> Void
    let onTakeOver: () -> Void
    let onHandBack: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            icon
            VStack(alignment: .leading, spacing: theme.z(1)) {
                Text(title)
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: theme.z(6))
            if state.userHasControl {
                Button("Hand back", action: onHandBack)
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Let the agent use the browser again")
            } else {
                Button("Take over", action: onTakeOver)
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Pause the agent and use the page yourself")
                Button("Stop", action: onStop)
                    .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                    .help("Refuse the agent's browser actions for the rest of this turn")
            }
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(7))
        .background(tint.opacity(theme.isDark ? 0.12 : 0.08))
        .accessibilityElement(children: .contain)
    }

    private var tint: Color { state.userHasControl ? theme.warning : theme.accent }

    @ViewBuilder private var icon: some View {
        Image(systemName: state.userHasControl ? "hand.raised" : "cursorarrow.motionlines")
            .font(theme.font(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: theme.z(18))
    }

    private var title: String {
        switch state.pause {
        case .signIn?: "This page asks you to sign in"
        case .tookOver?: "You have the browser"
        default: waiting ? "Agent is waiting for your permission" : "Agent is using the browser"
        }
    }

    private var detail: String? {
        switch state.pause {
        case .signIn?: "The agent is paused and does not type passwords. Sign in yourself, then hand the browser back."
        case .tookOver?: "The agent is paused until you hand the browser back."
        default: waiting ? nil : state.lastAction
        }
    }
}

/// Allow once, Always for this site (trusted folders only), or Deny for one browser call.
struct AgentBrowserPermissionCard: View {
    let request: BrowserPermissionRequest
    let answer: (BrowserPermissionAnswer) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "globe")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.warning)
                Text(question)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Text(request.tool.rawValue)
                    .font(theme.font(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: theme.z(3)) {
                Text(request.summary)
                    .font(theme.font(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let typed = request.typedText {
                    Text(typed.count > 300 ? String(typed.prefix(300)) + "\u{2026}" : typed)
                        .font(theme.font(size: 12.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("The text the agent would type")
                }
                Text(request.address)
                    .font(theme.font(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(8))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.separator))
            .textSelection(.enabled)

            if !request.allowsAlways {
                Text("This folder is not trusted, so each browser action asks.")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowRow(spacing: theme.z(8)) {
                Button("Allow once") { answer(.once) }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Allow this action only")
                if request.allowsAlways {
                    Button("Always for this site") { answer(.always) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Allow every browser action on \(request.site) for the rest of this session")
                }
                Button("Deny") { answer(.deny) }
                    .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                    .help("Refuse this action")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, theme.z(2))
        }
        .padding(theme.z(14))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.warning.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question) \(request.summary) on \(request.site)")
    }

    private var question: String {
        switch request.tool {
        case .browserNavigate: "Allow the agent to open this page?"
        case .browserSnapshot, .browserScreenshot, .browserConsole: "Allow the agent to read this page?"
        default: "Allow the agent to act on this page?"
        }
    }
}
