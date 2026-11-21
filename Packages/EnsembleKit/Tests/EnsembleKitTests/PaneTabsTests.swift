import Foundation
import Testing
@testable import EnsembleKit

@Suite struct PaneTabsTests {
    @Test func openingAddsOnceAndBringsForward() {
        var tabs = PaneTabs<String>()
        #expect(tabs.isEmpty)
        tabs.open("changes")
        tabs.open("terminal")
        tabs.open("changes")
        #expect(tabs.tabs == ["changes", "terminal"])
        #expect(tabs.active == "changes")
        #expect(tabs.contains("terminal"))
    }

    @Test func selectingOnlyWorksForAnOpenTab() {
        var tabs = PaneTabs<String>()
        tabs.open("changes")
        tabs.open("terminal")
        let known = tabs.select("changes")
        let unknown = tabs.select("browser")
        #expect(known)
        #expect(!unknown)
        #expect(tabs.active == "changes")
    }

    @Test func closingTheFrontTabBringsItsLeftNeighbourForward() {
        var tabs = PaneTabs<String>()
        for id in ["changes", "terminal", "browser"] { tabs.open(id) }
        let afterBrowser = tabs.close("browser")
        #expect(afterBrowser == "terminal")
        tabs.select("changes")
        let afterChanges = tabs.close("changes")
        #expect(afterChanges == "terminal")
        let afterLast = tabs.close("terminal")
        #expect(afterLast == nil)
        #expect(tabs.isEmpty)
    }

    @Test func closingAnotherTabKeepsTheFrontOne() {
        var tabs = PaneTabs<String>()
        for id in ["changes", "terminal", "browser"] { tabs.open(id) }
        let front = tabs.close("changes")
        #expect(front == "browser")
        #expect(tabs.tabs == ["terminal", "browser"])
        let unchanged = tabs.close("never-open")
        #expect(unchanged == "browser")
    }

    @Test func neighboursWrap() {
        var tabs = PaneTabs<String>()
        tabs.open("only")
        #expect(tabs.neighbour(1) == nil)
        tabs.open("second")
        tabs.open("third")
        #expect(tabs.neighbour(1) == "only")
        #expect(tabs.neighbour(-1) == "second")
    }

    @Test func closeAllEmptiesIt() {
        var tabs = PaneTabs<String>()
        tabs.open("a")
        tabs.closeAll()
        #expect(tabs.isEmpty)
        #expect(tabs.active == nil)
    }
}
