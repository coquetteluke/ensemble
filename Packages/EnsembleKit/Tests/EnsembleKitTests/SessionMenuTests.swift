import Foundation
import Testing
@testable import EnsembleKit

@Suite struct SessionMenuTests {
    private func titles(_ state: SessionMenuState) -> [String] {
        SessionMenu.sections(state).joined().map(\.title)
    }

    @Test func aPlainSessionGetsEveryRowInFourGroups() {
        let sections = SessionMenu.sections(SessionMenuState())
        #expect(sections.map { $0.map(\.action) } == [
            [.openInSplit, .pin],
            [.markUnread, .markCompleted],
            [.rename, .fork, .copyMarkdown, .revealFolder],
            [.archive, .delete],
        ])
    }

    @Test func titlesFollowTheSessionsState() {
        let fresh = titles(SessionMenuState())
        #expect(fresh.contains("Pin"))
        #expect(fresh.contains("Mark as unread"))
        #expect(fresh.contains("Mark as completed"))
        #expect(fresh.contains("Archive"))
        #expect(fresh.contains("Open in Split"))

        let marked = titles(SessionMenuState(pinned: true, unread: true, completed: true, archived: true, shownInSplit: true))
        #expect(marked.contains("Unpin"))
        #expect(marked.contains("Mark as read"))
        #expect(marked.contains("Mark as not completed"))
        #expect(marked.contains("Unarchive"))
        #expect(marked.contains("Show in Split"))
    }

    @Test func aHelperSessionHasNoPinOrMarks() {
        let actions = SessionMenu.sections(SessionMenuState(isSubagent: true)).joined().map(\.action)
        #expect(!actions.contains(.pin))
        #expect(!actions.contains(.markUnread))
        #expect(!actions.contains(.markCompleted))
        #expect(actions.contains(.rename))
        // The empty marks group is dropped, so no line is drawn for it.
        #expect(SessionMenu.sections(SessionMenuState(isSubagent: true)).count == 3)
    }

    @Test func onlyDeleteIsDestructive() {
        let destructive = SessionMenu.sections(SessionMenuState()).joined().filter(\.destructive).map(\.action)
        #expect(destructive == [.delete])
    }

    @Test func everyKeyIsUsedOnce() {
        for state in [SessionMenuState(), SessionMenuState(pinned: true, unread: true, completed: true, archived: true)] {
            let keys = SessionMenu.sections(state).joined().compactMap(\.key)
            #expect(Set(keys).count == keys.count)
        }
    }

    @Test func aKeyPicksItsRowInEitherCase() {
        let state = SessionMenuState()
        #expect(SessionMenu.item(forKey: "r", in: state)?.action == .rename)
        #expect(SessionMenu.item(forKey: "R", in: state)?.action == .rename)
        #expect(SessionMenu.item(forKey: "d", in: state)?.action == .delete)
        #expect(SessionMenu.item(forKey: "z", in: state) == nil)
    }

    @Test func aKeyDoesNothingForARowThatIsOff() {
        let state = SessionMenuState(canFork: false, canOpenBeside: false)
        #expect(SessionMenu.item(forKey: "f", in: state) == nil)
        #expect(SessionMenu.item(forKey: "o", in: state) == nil)
        let rows = SessionMenu.sections(state).joined()
        #expect(rows.first { $0.action == .fork }?.enabled == false)
        #expect(rows.first { $0.action == .openInSplit }?.enabled == false)
    }

    @Test func aTitleIsCleanedBeforeItIsSaved() {
        #expect(SessionMenu.cleanedTitle("  Fix the relay  ", current: "Old") == "Fix the relay")
        #expect(SessionMenu.cleanedTitle("Two\nlines", current: "Old") == "Two lines")
        #expect(SessionMenu.cleanedTitle("   \n ", current: "Old") == nil)
        #expect(SessionMenu.cleanedTitle("Old", current: "Old") == nil)
        #expect(SessionMenu.cleanedTitle(" Old ", current: "Old") == nil)
        let long = String(repeating: "a", count: 300)
        #expect(SessionMenu.cleanedTitle(long, current: "Old")?.count == 200)
    }
}
