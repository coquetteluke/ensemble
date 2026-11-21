import SwiftUI
import AppKit
import EnsembleKit

/// Checks the project's public release list for a newer Ensemble, when asked. It never downloads or installs: a
/// newer version is offered as a link to its release page.
@Observable @MainActor
final class UpdateCenter {
    static let shared = UpdateCenter()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    @ObservationIgnored var feed: any AppReleaseFeed = URLSessionReleaseFeed()

    init(state: State = .idle) {
        self.state = state
    }

    /// "0.1.0" from the app bundle.
    static var currentVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var buildText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    func check() async {
        guard state != .checking else { return }
        guard let current = AppVersion(Self.currentVersionText) else {
            state = .failed("This build has no version number to compare.")
            return
        }
        state = .checking
        do {
            let releases = try await feed.releases()
            switch AppUpdates.result(current: current, releases: releases) {
            case .upToDate: state = .upToDate
            case .available(let release, _): state = .available(release)
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Could not reach the release list. Check the connection and try again.")
        }
        lastChecked = Date()
    }

    /// Opens the release's page in the browser. Only pages on the project's own releases are opened.
    func openDownloadPage(_ release: AppRelease) {
        guard release.page.absoluteString.hasPrefix(AppUpdates.pagePrefix) else { return }
        NSWorkspace.shared.open(release.page)
    }
}

/// The About window: icon, name, version, the engine's version, and the update check.
struct AboutView: View {
    var updates: UpdateCenter = .shared
    /// The engine's version line, when the engine is running.
    var engineVersion: String?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    static let size = CGSize(width: 380, height: 400)

    var body: some View {
        VStack(spacing: theme.z(6)) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: theme.z(84), height: theme.z(84))
                .accessibilityHidden(true)
                .padding(.top, theme.z(26))
            Text("Ensemble")
                .font(theme.font(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(versionLine)
                .font(theme.font(size: 12.5).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
            if let engineVersion {
                Text("OpenCode \(engineVersion)")
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
            Text("Several AI models, coding together on your Mac.")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, theme.z(6))
            Spacer(minLength: theme.z(10))
            updateStatus
                .frame(minHeight: theme.z(74))
            Text("MIT licence. Built on OpenCode.")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, theme.z(16))
        }
        .padding(.horizontal, theme.z(28))
        .frame(width: theme.z(Self.size.width), height: theme.z(Self.size.height))
        .background(theme.background)
    }

    private var versionLine: String {
        let build = UpdateCenter.buildText
        return build.isEmpty ? "Version \(UpdateCenter.currentVersionText)" : "Version \(UpdateCenter.currentVersionText) (\(build))"
    }

    @ViewBuilder private var updateStatus: some View {
        VStack(spacing: theme.z(8)) {
            switch updates.state {
            case .idle:
                Button("Check for Updates") { Task { await updates.check() } }
                    .buttonStyle(SecondaryButtonStyle())
            case .checking:
                HStack(spacing: theme.z(8)) {
                    Spinner(size: 12)
                    Text("Checking for updates")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                }
            case .upToDate:
                Label("Ensemble is up to date", systemImage: "checkmark.circle")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.success)
                Button("Check Again") { Task { await updates.check() } }
                    .buttonStyle(SecondaryButtonStyle())
            case .available(let release):
                Text("Version \(release.version?.description ?? release.tag) is available")
                    .font(theme.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Button("Open the Download Page") { updates.openDownloadPage(release) }
                    .buttonStyle(PrimaryButtonStyle())
                    .help(release.page.absoluteString)
            case .failed(let message):
                Text(message)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await updates.check() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// The app menu's About and Check for Updates items. Both open the About window; the second also starts a check.
struct UpdateCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Ensemble") { openWindow(id: "about") }
            Button("Check for Updates\u{2026}") {
                openWindow(id: "about")
                Task { await UpdateCenter.shared.check() }
            }
            .disabled(AppEngine.usePreview)
        }
    }
}
