import SwiftUI
import AppKit
import EnsembleKit

/// One dev server: its name, command and port, what it is doing, and Start, Stop or Open.
struct DevServerRow: View {
    let page: BrowserPage
    let entry: LaunchEntry
    let servers: DevServers
    var onAction: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        let status = page.status(entry, servers: servers)
        HStack(alignment: .center, spacing: theme.z(10)) {
            dot(status)
            VStack(alignment: .leading, spacing: theme.z(2)) {
                HStack(spacing: theme.z(6)) {
                    Text(entry.name)
                        .font(theme.font(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(detail(status))
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(statusColor(status))
                        .lineLimit(1)
                }
                Text(entry.commandLine)
                    .font(theme.font(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.commandLine)
            }
            Spacer(minLength: theme.z(8))
            actions(status)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(9))
    }

    private func dot(_ status: DevServers.Status) -> some View {
        Group {
            if status == .starting {
                Spinner(size: 9)
            } else {
                StatusDot(statusColor(status), size: 7)
            }
        }
        .frame(width: theme.z(12))
    }

    private func detail(_ status: DevServers.Status) -> String {
        switch status {
        case .stopped: "Port \(entry.port)"
        case .starting: "Waiting for port \(entry.port)"
        case .running: "Running on port \(entry.port)"
        case .noAnswer: "Port \(entry.port) does not answer"
        case .ended(let reason): reason
        }
    }

    private func statusColor(_ status: DevServers.Status) -> Color {
        switch status {
        case .stopped: theme.textTertiary
        case .starting: theme.textSecondary
        case .running: theme.success
        case .noAnswer: theme.warning
        case .ended: theme.danger
        }
    }

    @ViewBuilder private func actions(_ status: DevServers.Status) -> some View {
        HStack(spacing: theme.z(6)) {
            if case .running(let url) = status {
                Button("Open") {
                    page.load(url)
                    onAction()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if status.isActive {
                Button("Stop") { page.stop(entry, servers: servers) }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Start") {
                    page.start(entry, servers: servers)
                    onAction()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// The dev servers popover: the folder's `.ensemble/launch.json` entries, or why there are none.
struct DevServersPopover: View {
    let page: BrowserPage
    let store: SessionStore
    let servers: DevServers
    let close: () -> Void
    @Environment(\.theme) private var theme

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text("Dev servers")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(LaunchConfig.relativePath)
                    .font(theme.font(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(4))
                IconButton("arrow.clockwise", help: "Read the file again", size: 24) { page.reloadLaunchConfig() }
            }
            .padding(.horizontal, theme.z(14))
            .padding(.top, theme.z(12))
            .padding(.bottom, theme.z(8))
            if !servers.trust.isTrusted(page.folder) {
                trustNotice
            }
            HLine(color: theme.border)
            content
        }
        .frame(width: theme.z(Self.width))
        .background(theme.popover)
    }

    private var trustNotice: some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: "lock.shield")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
            Text("Dev servers start only in folders you trust, because this file comes from the repository.")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, theme.z(14))
        .padding(.bottom, theme.z(10))
    }

    @ViewBuilder private var content: some View {
        switch page.launch {
        case .missing:
            VStack(alignment: .leading, spacing: theme.z(8)) {
                Text("This folder has no \(LaunchConfig.relativePath). Add one to start dev servers from here:")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.sample)
                    .font(theme.font(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .selectableText()
                    .padding(theme.z(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
            }
            .padding(theme.z(14))
        case .failed(let reason):
            Label { Text(reason).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
                .padding(theme.z(14))
        case .loaded(let config):
            VStack(alignment: .leading, spacing: 0) {
                if config.entries.isEmpty {
                    Text("The file lists no servers.")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(theme.z(14))
                }
                ForEach(config.entries) { entry in
                    DevServerRow(page: page, entry: entry, servers: servers, onAction: close)
                    HLine(color: theme.border)
                }
                ForEach(config.problems, id: \.self) { problem in
                    Label { Text(problem).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.warning)
                        .padding(.horizontal, theme.z(14))
                        .padding(.vertical, theme.z(5))
                }
                if !config.problems.isEmpty { Color.clear.frame(height: theme.z(6)) }
            }
        }
    }

    static let sample = """
    [
      {
        "name": "web",
        "command": "npm run dev",
        "port": 5173
      }
    ]
    """
}

/// Asks before the first start of a command in a folder, showing exactly what will run.
struct DevServerConfirmCard: View {
    let page: BrowserPage
    let pending: BrowserPage.PendingStart
    let servers: DevServers
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(9)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "play.circle")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.accent)
                Text("Start \(pending.entry.name)?")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            Text("This runs a command from \(LaunchConfig.relativePath) in \(Format.abbreviatedPath(page.folder)):")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(pending.entry.commandLine)
                .font(theme.font(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .selectableText()
                .padding(.horizontal, theme.z(10))
                .padding(.vertical, theme.z(8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
            VStack(alignment: .leading, spacing: theme.z(3)) {
                detail("Program", pending.program)
                detail("Port", "\(pending.entry.port), then opens \(pending.entry.url.absoluteString)")
            }
            HStack(spacing: theme.z(8)) {
                Text("Ensemble asks once for each folder and command.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: theme.z(8))
                Button("Cancel") { page.pendingStart = nil }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start") { page.start(pending.entry, servers: servers, confirmed: true) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(theme.z(14))
        .background(theme.elevated)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
            Text(label)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(54), alignment: .leading)
            Text(value)
                .font(theme.font(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .selectableText()
        }
    }
}

/// Why a start did not happen: the folder is not trusted, something is already on the port, or it failed.
struct DevServerNoticeRow: View {
    let page: BrowserPage
    let notice: BrowserPage.Notice
    let store: SessionStore
    let servers: DevServers
    @Environment(\.theme) private var theme
    @State private var trustError: String?

    var body: some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
            VStack(alignment: .leading, spacing: theme.z(7)) {
                Text(message)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let trustError {
                    Text(trustError)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch notice {
                case .needsTrust(let entry):
                    HStack(spacing: theme.z(8)) {
                        Button("Trust this folder") {
                            if store.trustFolder(page.folder) {
                                page.start(entry, servers: servers)
                            } else {
                                trustError = store.trustError(for: page.folder)
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Trust \(page.folder): agents load its own settings, and its dev servers can start")
                        Text(Format.abbreviatedPath(page.folder))
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                case .portInUse(_, let url):
                    Button("Open \(url.absoluteString)") {
                        page.notice = nil
                        page.load(url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                case .failed:
                    EmptyView()
                }
            }
            Spacer(minLength: theme.z(4))
            IconButton("xmark", help: "Dismiss", size: 22) { page.notice = nil }
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(9))
        .background(theme.elevated)
    }

    private var symbol: String {
        switch notice {
        case .needsTrust: "lock.shield"
        case .portInUse: "network"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch notice {
        case .needsTrust(let entry):
            "\(entry.name) did not start. Dev servers start only in folders you trust, because \(LaunchConfig.relativePath) "
                + "comes from the repository. Trusting also lets agents load this folder's own settings."
        case .portInUse(let name, let url):
            "\(name) did not start: something already answers on port \(url.port.map(String.init) ?? "")."
        case .failed(let reason):
            reason
        }
    }
}
