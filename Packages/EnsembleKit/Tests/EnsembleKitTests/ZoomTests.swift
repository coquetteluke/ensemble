import Foundation
import Testing
@testable import EnsembleKit

@Suite struct ZoomTests {
    @Test func stepsAreFivePercentApartFromSeventyToTwoHundred() {
        #expect(Zoom.steps.first == 0.7)
        #expect(Zoom.steps.last == 2)
        #expect(Zoom.steps.contains(1))
        for (a, b) in zip(Zoom.steps, Zoom.steps.dropFirst()) {
            #expect(abs((b - a) - 0.05) < 0.0001)
        }
    }

    @Test func onePressIsASmallChange() {
        #expect(Zoom.zoomIn(from: 1) == 1.05)
        #expect(Zoom.zoomOut(from: 1) == 0.95)
        #expect(Zoom.zoomIn(from: 1.05) == 1.1)
        #expect(Zoom.label(Zoom.zoomIn(from: 1.2)) == "125%")
    }

    @Test func theEndsHold() {
        #expect(Zoom.zoomIn(from: 2) == 2)
        #expect(Zoom.zoomOut(from: 0.7) == 0.7)
        #expect(Zoom.clamped(5) == 2)
        #expect(Zoom.clamped(0.1) == 0.7)
    }

    @Test func aSizeSavedWithTheOldStepsIsKept() {
        for old in [0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2] {
            #expect(abs(Zoom.clamped(old) - old) < 0.0001)
        }
    }
}
