import Foundation
import Testing
@testable import EnsembleKit

@Suite struct BackgroundHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, kind: BackgroundWorkItem.Kind = .shell, root: String = "s1", started: TimeInterval? = 0) -> BackgroundWorkItem {
        BackgroundWorkItem(id: id, kind: kind, title: id, rootSessionID: root, started: started.map { start.addingTimeInterval($0) })
    }

    @Test func aRowThatStopsBeingReportedHasFinished() {
        var history = BackgroundHistory()
        let first = history.update(running: [item("a"), item("b", started: 10)], at: start.addingTimeInterval(10))
        #expect(!first)
        #expect(history.finished.isEmpty)
        let second = history.update(running: [item("b", started: 10)], at: start.addingTimeInterval(42))
        #expect(second)
        #expect(history.finished.map(\.item.id) == ["a"])
        #expect(history.finished.first?.duration == 42)
        #expect(history.finished.first?.finished == start.addingTimeInterval(42))
    }

    @Test func nothingChangesWhileTheSameRowsRun() {
        var history = BackgroundHistory()
        history.update(running: [item("a")], at: start)
        let changed = history.update(running: [item("a")], at: start.addingTimeInterval(5))
        #expect(!changed)
        #expect(history.finished.isEmpty)
    }

    @Test func newestFirstAndCappedAtTheLimit() {
        var history = BackgroundHistory(limit: 2)
        history.update(running: [item("a"), item("b"), item("c")], at: start)
        history.update(running: [item("b"), item("c")], at: start.addingTimeInterval(1))
        history.update(running: [item("c")], at: start.addingTimeInterval(2))
        history.update(running: [], at: start.addingTimeInterval(3))
        #expect(history.finished.map(\.item.id) == ["c", "b"])
    }

    @Test func schedulesAreNeverTracked() {
        var history = BackgroundHistory()
        history.update(running: [item("next-run", kind: .schedule)], at: start)
        let changed = history.update(running: [], at: start.addingTimeInterval(60))
        #expect(!changed)
        #expect(history.finished.isEmpty)
    }

    @Test func aRowWithoutAStartHasNoDuration() {
        var history = BackgroundHistory()
        history.update(running: [item("a", started: nil)], at: start)
        history.update(running: [], at: start.addingTimeInterval(9))
        #expect(history.finished.first?.duration == nil)
    }

    @Test func finishedRowsFilterBySessionAndClear() {
        var history = BackgroundHistory()
        history.update(running: [item("a", root: "s1"), item("b", root: "s2"), item("c", root: "s1")], at: start)
        history.update(running: [item("c", root: "s1")], at: start.addingTimeInterval(4))
        #expect(history.finished(forSession: "s1").map(\.item.id) == ["a"])
        #expect(history.finished(forSession: "s2").map(\.item.id) == ["b"])
        history.clearFinished()
        #expect(history.finished.isEmpty)
        // What still runs is remembered, so it is recorded when it ends.
        history.update(running: [], at: start.addingTimeInterval(8))
        #expect(history.finished.map(\.item.id) == ["c"])
    }

    @Test func durationsReadShort() {
        #expect(BackgroundHistory.durationText(6) == "6s")
        #expect(BackgroundHistory.durationText(59.6) == "1m 00s")
        #expect(BackgroundHistory.durationText(185) == "3m 05s")
        #expect(BackgroundHistory.durationText(4320) == "1h 12m")
    }
}

@Suite struct ContextCompactionTests {
    private func breakdown(used: Int, limit: Int, _ categories: [(String, Int)]) -> ContextBreakdown {
        ContextBreakdown(usedTokens: used, limitTokens: limit,
                         categories: categories.map { ContextBreakdown.Category(key: $0.0, label: $0.0, tokens: $0.1) })
    }

    @Test func theFreeRowIsWhatIsLeft() {
        let context = breakdown(used: 466_900, limit: 1_000_000, [("messages", 403_300), ("buffer", 33_000), ("free", 499_800)])
        #expect(context.tokensBeforeCompacting == 499_800)
        #expect(context.compactingLine == "\(Format.tokens(499_800)) left before it compacts")
    }

    @Test func withoutAFreeRowItIsTheLimitLessUsedAndBuffer() {
        let context = breakdown(used: 150_000, limit: 200_000, [("messages", 150_000), ("buffer", 20_000)])
        #expect(context.tokensBeforeCompacting == 30_000)
        #expect(breakdown(used: 150_000, limit: 200_000, [("messages", 150_000)]).tokensBeforeCompacting == 50_000)
    }

    @Test func nothingLeftSaysItCompactsNext() {
        let context = breakdown(used: 195_000, limit: 200_000, [("messages", 195_000), ("buffer", 20_000)])
        #expect(context.tokensBeforeCompacting == 0)
        #expect(context.compactingLine == "Compacts on the next turn")
    }

    @Test func anUnknownWindowHasNoLine() {
        let context = breakdown(used: 46_000, limit: 0, [("messages", 46_000)])
        #expect(context.tokensBeforeCompacting == nil)
        #expect(context.compactingLine == nil)
    }
}
