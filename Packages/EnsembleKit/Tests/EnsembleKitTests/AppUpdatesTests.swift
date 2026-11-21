import Foundation
import Testing
@testable import EnsembleKit

@Suite struct AppUpdatesTests {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false,
                         page: String? = nil) -> AppRelease {
        AppRelease(tag: tag, page: URL(string: page ?? AppUpdates.pagePrefix + "tag/" + tag)!, isDraft: draft, isPrerelease: prerelease)
    }

    @Test func versionsCompareNumberByNumber() throws {
        let v010 = try #require(AppVersion("0.1.0"))
        let v02 = try #require(AppVersion("v0.2"))
        let v0110 = try #require(AppVersion("0.11.0"))
        #expect(v010 < v02)
        #expect(v02 < v0110)
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AppVersion("1.0")?.hashValue == AppVersion("1.0.0")?.hashValue)
        #expect(AppVersion("v1.2.3-beta+5")?.description == "1.2.3")
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("") == nil)
    }

    @Test func theNewestReleaseAboveTheCurrentVersionIsOffered() throws {
        let current = try #require(AppVersion("0.1.0"))
        let result = AppUpdates.result(current: current, releases: [release("v0.1.0"), release("v0.3.0"), release("v0.2.0"), release("nightly")])
        #expect(result == .available(release("v0.3.0"), current: current))
    }

    @Test func nothingNewerMeansUpToDate() throws {
        let current = try #require(AppVersion("0.3.0"))
        #expect(AppUpdates.result(current: current, releases: [release("v0.1.0"), release("v0.3.0")]) == .upToDate(current: current))
        #expect(AppUpdates.result(current: current, releases: []) == .upToDate(current: current))
    }

    @Test func draftsNeverCountAndPrereleasesCanBeLeftOut() throws {
        let current = try #require(AppVersion("0.1.0"))
        let releases = [release("v0.4.0", draft: true), release("v0.3.0", prerelease: true), release("v0.2.0")]
        #expect(AppUpdates.result(current: current, releases: releases) == .available(release("v0.3.0", prerelease: true), current: current))
        #expect(AppUpdates.result(current: current, releases: releases, includePrereleases: false) == .available(release("v0.2.0"), current: current))
    }

    @Test func aReleaseWhosePageIsElsewhereIsIgnored() throws {
        let current = try #require(AppVersion("0.1.0"))
        let elsewhere = release("v9.0.0", page: "https://example.com/download")
        #expect(AppUpdates.result(current: current, releases: [elsewhere]) == .upToDate(current: current))
        #expect(AppUpdates.result(current: current, releases: [elsewhere, release("v0.2.0")]) == .available(release("v0.2.0"), current: current))
    }

    @Test func theFeedDecodes() throws {
        let json = """
        [{"tag_name": "v0.1.0", "name": "Ensemble 0.1.0", "html_url": "https://github.com/coquetteluke/ensemble/releases/tag/v0.1.0",
          "draft": false, "prerelease": true, "published_at": "2026-11-20T23:30:00Z", "assets": [{"name": "Ensemble-0.1.0.dmg"}]}]
        """
        let releases = try AppUpdates.decode(Data(json.utf8))
        #expect(releases.count == 1)
        #expect(releases[0].tag == "v0.1.0")
        #expect(releases[0].name == "Ensemble 0.1.0")
        #expect(releases[0].isPrerelease)
        #expect(!releases[0].isDraft)
        #expect(releases[0].published != nil)
        #expect(releases[0].version == AppVersion("0.1.0"))
    }

    @Test func theFeedIsTheProjectsOwn() {
        #expect(AppUpdates.feed.host == "api.github.com")
        #expect(AppUpdates.feed.query == "per_page=20")
        #expect(AppUpdates.pagePrefix.hasPrefix("https://github.com/"))
    }

    @Test func errorsReadPlainly() {
        #expect(AppUpdateError.badResponse(403).errorDescription?.contains("Try again") == true)
        #expect(AppUpdateError.badResponse(500).errorDescription?.contains("500") == true)
    }
}
