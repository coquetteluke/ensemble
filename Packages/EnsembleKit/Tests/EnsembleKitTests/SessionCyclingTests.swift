import Foundation
import Testing
@testable import EnsembleKit

@Suite struct SessionCyclingTests {
    private let order = ["a", "b", "c"]

    @Test func stepsForwardAndBack() {
        #expect(SessionCycling.neighbour(of: "a", in: order, step: 1) == "b")
        #expect(SessionCycling.neighbour(of: "b", in: order, step: -1) == "a")
    }

    @Test func wrapsAtBothEnds() {
        #expect(SessionCycling.neighbour(of: "c", in: order, step: 1) == "a")
        #expect(SessionCycling.neighbour(of: "a", in: order, step: -1) == "c")
    }

    @Test func withNothingSelectedItStartsAtAnEnd() {
        #expect(SessionCycling.neighbour(of: nil, in: order, step: 1) == "a")
        #expect(SessionCycling.neighbour(of: nil, in: order, step: -1) == "c")
        #expect(SessionCycling.neighbour(of: "gone", in: order, step: 1) == "a")
    }

    @Test func nowhereToGo() {
        #expect(SessionCycling.neighbour(of: "a", in: ["a"], step: 1) == nil)
        #expect(SessionCycling.neighbour(of: nil, in: [], step: 1) == nil)
        #expect(SessionCycling.neighbour(of: "a", in: order, step: 0) == nil)
        #expect(SessionCycling.neighbour(of: "a", in: order, step: 3) == nil)
    }
}
