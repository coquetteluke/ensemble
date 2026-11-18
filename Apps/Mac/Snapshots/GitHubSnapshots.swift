import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the pull request bar in every state (one sheet per colour scheme), the Create pull request
/// form, the Create branch field and the GitHub settings section, in dark and light at the requested zoom.
/// Called from `SnapshotRenderer.run`. Nothing here runs gh or git unless `ENSEMBLE_GITHUB_CHECK_REPO` is set.
@MainActor
enum GitHubSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("github-bar-states-\(tone)\(suffix)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                StatesSheet(cases: cases())
            }
            written += save("github-pr-form-\(tone)\(suffix)", to: directory, width: 560, zoom: zoom, scheme: scheme) {
                PullRequestFormSheet(controller: formController(error: nil))
            }
            written += save("github-pr-form-error-\(tone)\(suffix)", to: directory, width: 560, zoom: zoom, scheme: scheme) {
                PullRequestFormSheet(controller: formController(error: "origin has commits on ensemble/fix-the-readme that this folder does not. Pull them first; Ensemble never force-pushes."))
            }
            written += save("github-create-branch-\(tone)\(suffix)", to: directory, width: 340, zoom: zoom, scheme: scheme) {
                CreateBranchPopover(controller: .preview(state: .defaultBranch(branch: "main"), local: local(branch: "main"), cli: signedIn,
                                                         branchName: "ensemble/fix-the-readme"))
            }
            let settings: [(String, GitHubCLIStatus, Bool)] = [("signed-in", signedIn, true), ("not-installed", .notInstalled, false),
                                                                ("signed-out", signedOutStatus, false)]
            for (name, status, helper) in settings {
                if let path = captureOffscreen(GitHubSettingsTab(statusOverride: status, helperOverride: helper).frame(width: 560, height: 400),
                                               size: CGSize(width: 560, height: 400), zoom: zoom, scheme: scheme,
                                               to: directory.appendingPathComponent("settings-github-\(name)-\(tone)\(suffix).png")) {
                    written.append(path)
                }
            }
        }
        written += checkLive(to: directory)
        print("Rendered \(written.count) GitHub snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Sample states

    static let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
    static let branch = "ensemble/fix-the-readme"
    static let signedIn = GitHubCLIStatus.installed(GitHubCLIInfo(path: "/opt/homebrew/bin/gh", version: "2.103.3", accounts: [
        GitHubAccount(host: "github.com", login: "octocat", active: true, state: .valid),
    ]))
    static let signedOutStatus = GitHubCLIStatus.installed(GitHubCLIInfo(path: "/opt/homebrew/bin/gh", version: "2.103.3"))

    static func local(branch: String = GitHubSnapshots.branch, published: Bool = true, unpushed: Int? = 0, ahead: Int? = 2,
                      uncommitted: Int = 0) -> GitHubLocalRepo {
        GitHubLocalRepo(root: "/Projects/widgets", branch: branch, remoteName: "origin", remote: remote, defaultBranch: "main",
                        published: published, unpushed: published ? unpushed : nil, ahead: ahead, uncommitted: uncommitted)
    }

    static func checks(_ buckets: [GitHubCheck.Bucket]) -> [GitHubCheck] {
        let names = ["lint", "test", "build", "docs"]
        return buckets.enumerated().map { index, bucket in
            GitHubCheck(name: names[index % names.count], workflow: "CI", bucket: bucket,
                        link: "https://github.com/acme/widgets/actions/runs/1001/job/\(2001 + index)")
        }
    }

    static func pr(_ state: GitHubPullRequest.State = .open, checks buckets: [GitHubCheck.Bucket], review: GitHubPullRequest.ReviewDecision? = nil,
                   draft: Bool = false, autoMerge: Bool = false) -> GitHubPullRequest {
        GitHubPullRequest(number: 42, title: "Name the app in the README and check it in CI", url: "https://github.com/acme/widgets/pull/42",
                          state: state, isDraft: draft, reviewDecision: review, autoMergeEnabled: autoMerge, headRefName: branch,
                          baseRefName: "main", checks: checks(buckets))
    }

    struct Case: Identifiable {
        let title: String
        let controller: GitHubPullRequestController
        var id: String { title }
    }

    static func cases() -> [Case] {
        let failing = pr(checks: [.pass, .fail, .pass, .fail], review: .changesRequested)
        let passing = pr(checks: [.pass, .pass, .skipping], review: .approved)
        return [
            Case(title: "gh not installed", controller: .preview(state: .needsCLI, local: local(), cli: .notInstalled)),
            Case(title: "Signed out", controller: .preview(state: .signedOut(host: "github.com", problem: nil), local: local(), cli: signedOutStatus)),
            Case(title: "Sign-in no longer works", controller: .preview(
                state: .signedOut(host: "github.com", problem: "The sign-in for octocat on github.com no longer works"), local: local(), cli: signedOutStatus)),
            Case(title: "Default branch", controller: .preview(state: .defaultBranch(branch: "main"), local: local(branch: "main"), cli: signedIn)),
            Case(title: "Branch without a pull request", controller: .preview(state: .noPullRequest(branch: branch, base: "main"),
                                                                              local: local(published: false, ahead: 3, uncommitted: 2), cli: signedIn)),
            Case(title: "Branch with nothing to open", controller: .preview(state: .noPullRequest(branch: branch, base: "main"),
                                                                            local: local(published: false, ahead: 0), cli: signedIn)),
            Case(title: "Checks pending, review required", controller: .preview(
                state: .pullRequest(pr(checks: [.pass, .pending, .pending], review: .reviewRequired)), local: local(), cli: signedIn)),
            Case(title: "Checks failing, changes requested, a commit to push", controller: .preview(
                state: .pullRequest(failing), local: local(unpushed: 1), cli: signedIn)),
            Case(title: "Fetching the failed logs", controller: .preview(state: .pullRequest(failing), local: local(), cli: signedIn, busy: [.fixing])),
            Case(title: "After Fix checks", controller: .preview(state: .pullRequest(failing), local: local(), cli: signedIn,
                                                                notice: "Queued the failed logs until the agent's turn ends")),
            Case(title: "Checks passing, approved", controller: .preview(state: .pullRequest(passing), local: local(), cli: signedIn)),
            Case(title: "Auto-merge on", controller: .preview(
                state: .pullRequest(pr(checks: [.pass, .pending], review: .approved, autoMerge: true)), local: local(), cli: signedIn, autoArchive: true)),
            Case(title: "Draft", controller: .preview(state: .pullRequest(pr(checks: [.pass, .pass], draft: true)), local: local(), cli: signedIn)),
            Case(title: "Merged", controller: .preview(state: .pullRequest(pr(.merged, checks: [.pass, .pass], review: .approved)),
                                                      local: local(), cli: signedIn)),
            Case(title: "Closed", controller: .preview(state: .pullRequest(pr(.closed, checks: [.pass, .fail])), local: local(), cli: signedIn)),
            Case(title: "Push refused", controller: .preview(
                state: .pullRequest(passing), local: local(unpushed: 1), cli: signedIn,
                actionError: "origin has commits on ensemble/fix-the-readme that this folder does not. Pull them first; Ensemble never force-pushes.")),
            Case(title: "GitHub did not answer", controller: .preview(state: .failed("HTTP 502: Server Error"), local: local(), cli: signedIn)),
        ]
    }

    static func formController(error: String?) -> GitHubPullRequestController {
        let form = GitHubPullRequestForm(
            title: "Name the app in the README and check it in CI",
            body: "The README still called the app by its old name, and nothing caught it.\n\n- Rename the app in the README\n- Add a CI step that checks the name\n\nTested with swift test and the new CI step.",
            base: "main", head: branch, remote: remote)
        let controller = GitHubPullRequestController.preview(state: .noPullRequest(branch: branch, base: "main"),
                                                             local: local(published: false, ahead: 2), cli: signedIn, form: form)
        controller.formError = error
        return controller
    }

    /// Every state, each under a caption, as one tall image.
    private struct StatesSheet: View {
        let cases: [Case]
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(14)) {
                ForEach(cases) { item in
                    VStack(alignment: .leading, spacing: theme.z(5)) {
                        Text(item.title)
                            .font(theme.font(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                        PullRequestBar(controller: item.controller)
                    }
                }
            }
            .padding(theme.z(20))
        }
    }

    // MARK: Rendering

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = Canvas(width: w) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        return write(image, to: directory.appendingPathComponent(name + ".png")).map { [$0] } ?? []
    }

    private struct Canvas<Content: View>: View {
        let width: CGFloat
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.background)
        }
    }

    private static func write(_ image: CGImage, to url: URL) -> String? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }

    /// Grouped forms are drawn by AppKit, so the settings are captured from a window that is never shown.
    private static func captureOffscreen<V: View>(_ view: V, size: CGSize, zoom: CGFloat, scheme: ColorScheme, to url: URL) -> String? {
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let root = view
            .ensembleTheme()
            .environment(\.zoom, zoom)
            .environment(\.isSnapshot, true)
            .preferredColorScheme(scheme)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: scaled)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let image = rep.cgImage else { return nil }
        return write(image, to: url)
    }

    // MARK: Live check

    /// With `ENSEMBLE_GITHUB_CHECK_REPO` set to a throwaway repository whose origin looks like GitHub (and
    /// `ENSEMBLE_GH_PATH` pointing at a fake gh), hosts the real bar in a window that is never shown and lets its
    /// own refresh loop run against the folder. Prints the state it reached and saves `github-bar-live.png`.
    private static func checkLive(to directory: URL) -> [String] {
        guard let repo = ProcessInfo.processInfo.environment["ENSEMBLE_GITHUB_CHECK_REPO"], !repo.isEmpty else { return [] }
        let setting = GitHubAutoArchiveSetting(defaults: UserDefaults(suiteName: "ensemble-github-live-check") ?? .standard)
        let controller = GitHubPullRequestController(sessionID: "live", hooks: .inert(directory: repo, title: "Live check"),
                                                     service: GitHubService(), setting: setting)
        let root = PullRequestBarContainer(controller: controller, isAgentWorking: false)
            .frame(width: 720)
            .padding(20)
            .ensembleTheme()
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 760, height: 90)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        let deadline = Date().addingTimeInterval(15)
        while !controller.state.isVisible, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var paths: [String] = []
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let image = rep.cgImage, let path = write(image, to: directory.appendingPathComponent("github-bar-live.png")) { paths.append(path) }
        }
        // Take the bar out of the window so its refresh loop ends before the next snapshots run.
        window.contentView = nil
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("GitHub check: state \(controller.state), visible \(controller.isVisible)")
        return paths
    }
}
