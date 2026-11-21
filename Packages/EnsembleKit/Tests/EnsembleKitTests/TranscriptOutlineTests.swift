import Foundation
import Testing
@testable import EnsembleKit

@Suite struct TranscriptOutlineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func user(_ id: String, _ text: String, minute: Double = 0) -> TranscriptItem {
        .user(id: id, text: text, date: now.addingTimeInterval(minute * 60))
    }

    private func edit(_ path: String) -> TranscriptItem {
        .tool(ToolCallInfo(id: UUID().uuidString, name: "edit", title: path, status: .succeeded))
    }

    private func agent(_ text: String) -> TranscriptItem {
        .agentText(id: UUID().uuidString, text: text, agentID: nil, streaming: false)
    }

    @Test func oneEntryPerMessageYouSentInOrder() {
        let items = [user("u1", "Build the context panel", minute: 0), agent("On it."), edit("a.swift"), edit("b.swift"),
                     user("u2", "Now the tests", minute: 5), agent("Done."),
                     user("u3", "/compact", minute: 9)]
        let entries = TranscriptOutline.entries(items)
        #expect(entries.map(\.id) == ["u1", "u2", "u3"])
        #expect(entries.map(\.number) == [1, 2, 3])
        #expect(entries.map(\.title) == ["Build the context panel", "Now the tests", "/compact"])
        #expect(entries.map(\.filesChanged) == [2, 0, 0])
        #expect(entries[1].date == now.addingTimeInterval(300))
    }

    @Test func pinnedMessagesAreChapters() {
        let items = [user("u1", "One"), user("u2", "Two"), user("u3", "Three")]
        let entries = TranscriptOutline.entries(items, pinned: ["u2", "gone"])
        #expect(entries.map(\.pinned) == [false, true, false])
        #expect(TranscriptOutline.visible(entries, chaptersOnly: true).map(\.id) == ["u2"])
        #expect(TranscriptOutline.visible(entries, chaptersOnly: false).count == 3)
    }

    @Test func aTranscriptWithoutYourMessagesHasNoOutline() {
        #expect(TranscriptOutline.entries([agent("Hello"), edit("a.swift")]).isEmpty)
        #expect(TranscriptOutline.entries([]).isEmpty)
    }

    @Test func titlesAreOneShortLine() {
        #expect(TranscriptOutline.title("\n\n  Fix   the\trelay  \nand more") == "Fix the relay")
        #expect(TranscriptOutline.title("   ") == "Attachment")
        let long = String(repeating: "word ", count: 40)
        let title = TranscriptOutline.title(long)
        #expect(title.count <= 80)
        #expect(title.hasSuffix("\u{2026}"))
        #expect(TranscriptOutline.title("short", limit: 80) == "short")
    }

    @Test func theSameFileEditedTwiceCountsOnce() {
        let items = [user("u1", "Go"), edit("a.swift"), edit("a.swift"), agent("Done.")]
        #expect(TranscriptOutline.entries(items).first?.filesChanged == 1)
    }
}
