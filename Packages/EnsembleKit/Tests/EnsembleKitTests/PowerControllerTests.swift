import Foundation
import Testing
@testable import EnsembleKit

@Suite @MainActor struct PowerControllerTests {
    let a = PowerHolderID.session("ses_a")
    let b = PowerHolderID.session("ses_b")

    // MARK: Dependency rule

    @Test func levelSwitchesFollowTheDependencyRule() {
        // Lid lock on turns Keep awake on.
        #expect(PowerLevel.off.settingLidLock(true) == .lidLock)
        #expect(PowerLevel.lidLock.keepAwake)
        // Keep awake off turns lid lock off.
        #expect(PowerLevel.lidLock.settingKeepAwake(false) == .off)
        // Keep awake can be on alone, and lid lock off leaves it on.
        #expect(PowerLevel.off.settingKeepAwake(true) == .awake)
        #expect(PowerLevel.lidLock.settingLidLock(false) == .awake)
        #expect(PowerLevel.awake.settingLidLock(false) == .awake)
        // Keep awake on does not lower lid lock.
        #expect(PowerLevel.lidLock.settingKeepAwake(true) == .lidLock)
    }

    @Test func controllerAppliesTheDependencyRuleBothWays() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.level(for: a) == .lidLock)
        #expect(h.backend.snapshot.awakeHeld)
        #expect(h.backend.snapshot.sleepDisabled)

        h.controller.setKeepAwake(false, for: a)
        await h.settle()
        #expect(h.controller.level(for: a) == .off)
        #expect(!h.backend.snapshot.awakeHeld)
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands == ["disablesleep 1", "disablesleep 0"])

        h.controller.setKeepAwake(true, for: a)
        await h.settle()
        #expect(h.controller.level(for: a) == .awake)
        #expect(h.backend.snapshot.awakeHeld)
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(h.controller.heldLevel == .awake)
    }

    // MARK: Max over holders

    @Test func effectiveLevelIsTheMaxOverHolders() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setWorking(true, for: a)
        h.controller.setWorking(true, for: b)
        h.controller.setKeepAwake(true, for: a)
        h.controller.setLidLock(true, for: b)
        await h.settle()
        #expect(h.controller.effectiveLevel == .lidLock)
        #expect(h.controller.heldLevel == .lidLock)
        #expect(h.controller.lidLockSource == .owned)
        #expect(h.controller.activeHolders.map(\.id) == [b, a])

        // B drops lid lock: A still keeps the Mac awake, lid lock is released.
        h.controller.setLidLock(false, for: b)
        h.controller.setKeepAwake(false, for: b)
        await h.settle()
        #expect(h.controller.effectiveLevel == .awake)
        #expect(h.backend.snapshot.awakeHeld)
        #expect(!h.backend.snapshot.sleepDisabled)

        // A turns off too: nothing is held.
        h.controller.setKeepAwake(false, for: a)
        await h.settle()
        #expect(h.controller.effectiveLevel == .off)
        #expect(!h.backend.snapshot.awakeHeld)
        #expect(h.backend.snapshot.awakeHoldCount == 1)
    }

    // MARK: Grace period

    @Test func idleHolderReleasesAfterTheGracePeriodAndKeepsItsSwitch() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setWorking(true, for: a)
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.isHolding(a))

        h.controller.setWorking(false, for: a)
        h.clock.advance(minutes: 9)
        await h.controller.refresh()
        await h.settle()
        #expect(h.controller.isHolding(a))
        #expect(h.backend.snapshot.sleepDisabled)

        h.clock.advance(minutes: 2)
        await h.controller.refresh()
        await h.settle()
        #expect(!h.controller.isHolding(a))
        #expect(!h.backend.snapshot.awakeHeld)
        #expect(!h.backend.snapshot.sleepDisabled)
        // The switch is remembered for the next time it works.
        #expect(h.controller.level(for: a) == .lidLock)

        h.controller.setWorking(true, for: a)
        await h.settle()
        #expect(h.controller.isHolding(a))
        #expect(h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands == ["disablesleep 1", "disablesleep 0", "disablesleep 1"])
    }

    @Test func turningASwitchOnWhileIdleHoldsForTheGracePeriod() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setGracePeriod(300)
        h.controller.setKeepAwake(true, for: a)
        #expect(h.controller.isHolding(a))
        h.clock.advance(minutes: 6)
        await h.controller.refresh()
        #expect(!h.controller.isHolding(a))
        #expect(h.controller.level(for: a) == .awake)
    }

    @Test func workingHolderNeverTimesOut() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setKeepAwake(true, for: a)
        h.controller.setWorking(true, for: a)
        h.clock.advance(minutes: 120)
        await h.controller.refresh()
        #expect(h.controller.isHolding(a))
    }

    // MARK: A lid lock set outside Ensemble

    @Test func neverTurnsOffALidLockThatWasAlreadyOn() async {
        let h = PowerHarness(.init(sleepDisabled: true))
        await h.start()
        h.controller.setWorking(true, for: a)
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.lidLockSource == .external)
        #expect(h.controller.heldLevel == .lidLock)

        h.controller.setLidLock(false, for: a)
        h.controller.setWorking(false, for: a)
        await h.settle()
        #expect(h.controller.lidLockSource == .off)
        #expect(h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands.isEmpty)
        #expect(!h.marker.exists)

        // Quitting does not touch it either.
        h.controller.releaseAllForQuit()
        #expect(h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands.isEmpty)
    }

    @Test func handsOverToTheLidlockToolInsteadOfTurningItOff() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.lidLockSource == .owned)

        // Luke runs `lidlock on` while Ensemble holds it.
        h.backend.update { $0.toolActive = true }
        h.controller.setLidLock(false, for: a)
        await h.settle()
        #expect(h.controller.lidLockSource == .off)
        #expect(h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands == ["disablesleep 1"])
        #expect(!h.marker.exists)
    }

    @Test func lidLockTurnedOffOutsideEnsembleTurnsTheSwitchesOff() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setWorking(true, for: a)
        h.controller.setLidLock(true, for: a)
        await h.settle()
        h.backend.update { $0.sleepDisabled = false }
        await h.controller.refresh()
        await h.settle()
        #expect(h.controller.lidLockSource == .off)
        #expect(h.controller.level(for: a) == .awake)
        #expect(h.controller.notice != nil)
        #expect(h.backend.snapshot.commands == ["disablesleep 1"])
        #expect(!h.marker.exists)
        #expect(h.backend.snapshot.awakeHeld)
    }

    // MARK: Quit

    @Test func quitReleasesEverything() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setWorking(true, for: a)
        h.controller.setWorking(true, for: b)
        h.controller.setLidLock(true, for: a)
        h.controller.setKeepAwake(true, for: b)
        await h.settle()
        #expect(h.marker.exists)

        h.controller.releaseAllForQuit()
        #expect(!h.backend.snapshot.awakeHeld)
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(!h.marker.exists)
        #expect(h.controller.heldLevel == .off)
        // Switches stay remembered for the next launch.
        let next = PowerController(backend: FakePowerBackend(), marker: h.marker, defaults: h.defaults, schedulesTimers: false)
        #expect(next.level(for: a) == .lidLock)
        #expect(next.level(for: b) == .awake)
        #expect(!next.isHolding(a))
    }

    // MARK: Crash recovery

    @Test func markerFromACrashTurnsLidLockOffAtLaunch() async {
        let h = PowerHarness(.init(sleepDisabled: true), markerExists: true)
        await h.start()
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands == ["disablesleep 0"])
        #expect(!h.marker.exists)
        #expect(h.controller.notice != nil)
    }

    @Test func noMarkerLeavesALidLockAloneAtLaunch() async {
        let h = PowerHarness(.init(sleepDisabled: true))
        await h.start()
        #expect(h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands.isEmpty)
    }

    @Test func markerIsDroppedWhenTheLidlockToolNowHoldsIt() async {
        let h = PowerHarness(.init(sleepDisabled: true, toolActive: true), markerExists: true)
        await h.start()
        #expect(h.backend.snapshot.sleepDisabled)
        #expect(h.backend.snapshot.commands.isEmpty)
        #expect(!h.marker.exists)
    }

    @Test func markerIsWrittenBeforeLidLockTurnsOn() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.backend.snapshot.markerExistedOnEnable == [true])
        #expect(h.marker.exists)
        h.controller.setLidLock(false, for: a)
        await h.settle()
        #expect(!h.marker.exists)
    }

    // MARK: Setup

    @Test func missingSudoRuleAsksForSetupOnceThenWorksAfterSetup() async {
        let h = PowerHarness(.init(sudoReady: false))
        await h.start()
        #expect(h.controller.sudoStatus == .missing)
        h.controller.setWorking(true, for: a)
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.lidLockProblem == .needsSetup)
        #expect(!h.marker.exists)
        // Keep awake still works without the rule.
        #expect(h.backend.snapshot.awakeHeld)

        // Later changes do not retry the failing command.
        h.controller.setWorking(true, for: b)
        h.controller.setKeepAwake(true, for: b)
        await h.controller.refresh()
        await h.settle()
        #expect(h.backend.snapshot.commands == ["disablesleep 1"])

        await h.controller.runSetup()
        await h.settle()
        #expect(h.controller.sudoStatus == .ready)
        #expect(h.controller.lidLockProblem == nil)
        #expect(h.controller.lidLockSource == .owned)
        #expect(h.backend.snapshot.sleepDisabled)
    }

    @Test func cancelledSetupLeavesTheProblem() async {
        let h = PowerHarness(.init(sudoReady: false, installResult: .cancelled))
        await h.start()
        h.controller.setLidLock(true, for: a)
        await h.settle()
        await h.controller.runSetup()
        await h.settle()
        #expect(h.controller.sudoStatus == .missing)
        #expect(h.controller.lidLockProblem == .needsSetup)
        #expect(h.controller.setupMessage == nil)
        #expect(!h.backend.snapshot.sleepDisabled)
    }

    // MARK: Deleted holders, persistence, Macs without a lid

    @Test func deletedSessionStopsHoldingAndIsForgotten() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setWorking(true, for: a)
        h.controller.setLidLock(true, for: a)
        h.controller.setKeepAwake(true, for: b)
        await h.settle()
        h.controller.syncExisting([b], kind: .session)
        await h.settle()
        #expect(h.controller.level(for: a) == .off)
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(h.controller.isHolding(b))

        let room = PowerHolderID.room(UUID())
        h.controller.setKeepAwake(true, for: room)
        h.controller.syncExisting([], kind: .session)
        #expect(h.controller.level(for: room) == .awake)
        h.controller.remove(room)
        #expect(!h.backend.snapshot.awakeHeld)
    }

    @Test func syncWorkingMarksOnlyListedHoldersWorking() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setKeepAwake(true, for: a)
        h.controller.setKeepAwake(true, for: b)
        h.controller.syncWorking([a, b], kind: .session)
        h.controller.syncWorking([a], kind: .session)
        h.clock.advance(minutes: 11)
        await h.controller.refresh()
        #expect(h.controller.isHolding(a))
        #expect(!h.controller.isHolding(b))
    }

    @Test func gracePeriodIsSaved() {
        let h = PowerHarness()
        h.controller.setGracePeriod(1800)
        let next = PowerController(backend: FakePowerBackend(), marker: h.marker, defaults: h.defaults, schedulesTimers: false)
        #expect(next.gracePeriod == 1800)
        #expect(PowerHarness().controller.gracePeriod == PowerController.defaultGracePeriod)
    }

    @Test func macWithoutALidOnlyKeepsAwake() async {
        let h = PowerHarness(.init(sudoReady: false, lid: false))
        await h.start()
        #expect(!h.controller.hasLid)
        #expect(h.backend.snapshot.sudoChecks == 0)
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.effectiveLevel == .awake)
        #expect(h.backend.snapshot.awakeHeld)
        #expect(h.backend.snapshot.commands.isEmpty)
        #expect(h.controller.lidLockProblem == nil)
    }

    @Test func batteryWarningShowsOnlyWithLidLockOnBattery() async {
        let h = PowerHarness(.init(battery: true))
        await h.start()
        h.controller.setKeepAwake(true, for: a)
        #expect(!h.controller.showsBatteryWarning)
        h.controller.setLidLock(true, for: a)
        await h.settle()
        #expect(h.controller.showsBatteryWarning)
        h.backend.update { $0.battery = false }
        await h.controller.refresh()
        #expect(!h.controller.showsBatteryWarning)
    }

    @Test func turnOffAllReleasesEverything() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setLidLock(true, for: a)
        h.controller.setKeepAwake(true, for: b)
        await h.settle()
        h.controller.turnOffAll()
        await h.settle()
        #expect(h.controller.heldLevel == .off)
        #expect(h.controller.level(for: a) == .off)
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(!h.backend.snapshot.awakeHeld)
    }

    @Test func togglingQuicklyEndsInTheLastState() async {
        let h = PowerHarness()
        await h.start()
        h.controller.setLidLock(true, for: a)
        h.controller.setLidLock(false, for: a)
        h.controller.setLidLock(true, for: a)
        h.controller.setKeepAwake(false, for: a)
        await h.settle()
        #expect(!h.backend.snapshot.sleepDisabled)
        #expect(h.controller.lidLockSource == .off)
        #expect(!h.marker.exists)
    }
}
