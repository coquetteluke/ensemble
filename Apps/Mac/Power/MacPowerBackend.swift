import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Synchronization
import EnsembleKit

/// The real power backend: IOKit power assertions for Keep awake, `sudo -n pmset disablesleep` for lid
/// lock (the same method as Luke's `lidlock`), and `osascript` for the one-time sudoers setup.
final class MacPowerBackend: PowerBackend {
    /// Assertion ids while Keep awake is held.
    private let assertions = Mutex<[IOPMAssertionID]>([])
    /// Serialises pmset commands, so a release at quit runs after a command still in flight.
    private let pmsetLock = Mutex<Void>(())

    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"
    /// Luke's `lidlock` keeps `caffeinate -dims` running while it is on and writes its pid here.
    private static let lidlockPIDPath = NSHomeDirectory() + "/.local/share/lidlock/awake.pid"

    // MARK: Keep awake

    func holdAwake(reason: String) -> Bool {
        assertions.withLock { ids in
            if !ids.isEmpty { return true }
            // Idle system sleep and idle display sleep, so the screen does not dim or lock (like caffeinate -d).
            var created: [IOPMAssertionID] = []
            for type in ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"] {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                         reason as CFString, &id)
                if result == kIOReturnSuccess { created.append(id) }
            }
            guard created.count == 2 else {
                created.forEach { IOPMAssertionRelease($0) }
                return false
            }
            ids = created
            return true
        }
    }

    func releaseAwake() {
        assertions.withLock { ids in
            ids.forEach { IOPMAssertionRelease($0) }
            ids.removeAll()
        }
    }

    // MARK: Lid lock

    func readSleepDisabled() -> Bool? {
        let result = PowerShell.run(Self.pmset, ["-g"])
        guard result.status == 0 else { return nil }
        // pmset omits the line on some systems while it is 0.
        return PowerParsing.sleepDisabled(fromPMSet: result.output) ?? false
    }

    func setSleepDisabled(_ disabled: Bool) -> PowerCommandResult {
        pmsetLock.withLock { _ in
            let result = PowerShell.run(Self.sudo, ["-n", Self.pmset, "disablesleep", disabled ? "1" : "0"], timeout: 15)
            if result.status == 0 { return .ok }
            if PowerParsing.sudoWantedPassword(result.error) { return .needsSetup }
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "pmset exited with status \(result.status)." : message)
        }
    }

    func sudoRuleStatus() -> SudoRuleStatus {
        // Lists the rules without running anything. Works without a password when at least one rule is NOPASSWD.
        let result = PowerShell.run(Self.sudo, ["-n", "-l"], timeout: 15)
        return result.status == 0 && PowerParsing.sudoListingAllowsPMSet(result.output) ? .ready : .missing
    }

    func installSudoRule() -> PowerSetupResult {
        let user = NSUserName()
        guard let source = PowerSudoers.appleScript(user: user) else {
            return .failed("The user name \(user) cannot be used in a sudo rule.")
        }
        // macOS shows its own administrator password dialog; the password never reaches Ensemble.
        let result = PowerShell.run("/usr/bin/osascript", ["-e", source], timeout: 600)
        if result.status == 0 { return .installed }
        if result.error.contains("-128") || result.error.localizedCaseInsensitiveContains("canceled") {
            return .cancelled
        }
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "Setup exited with status \(result.status)." : message)
    }

    // MARK: Hardware

    func hasLid() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
            return value?.takeRetainedValue() != nil
        }
        let result = PowerShell.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"])
        return PowerParsing.hasLid(fromIoreg: result.output)
    }

    func isOnBattery() -> Bool {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            return (type as String) == "Battery Power"
        }
        return PowerParsing.onBattery(fromPMSetPS: PowerShell.run(Self.pmset, ["-g", "ps"]).output)
    }

    func externalLidLockToolActive() -> Bool {
        guard let text = try? String(contentsOfFile: Self.lidlockPIDPath, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        // Same check as lidlock itself: the pid must still be a caffeinate.
        let result = PowerShell.run("/bin/ps", ["-p", String(pid), "-o", "comm="])
        return result.status == 0 && result.output.contains("caffeinate")
    }
}

/// Runs a command and collects its output, with a timeout.
enum PowerShell {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    private final class Output: Sendable {
        private let data = Mutex<(out: Data, err: Data)>((Data(), Data()))
        func setOut(_ value: Data) { data.withLock { $0.out = value } }
        func setErr(_ value: Data) { data.withLock { $0.err = value } }
        var value: (out: Data, err: Data) { data.withLock { $0 } }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        // Read both pipes while the process runs, so a full pipe cannot block it.
        let output = Output()
        let readers = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async(group: readers) { output.setOut(outHandle.readDataToEndOfFile()) }
        DispatchQueue.global(qos: .userInitiated).async(group: readers) { output.setErr(errHandle.readDataToEndOfFile()) }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        _ = readers.wait(timeout: .now() + 2)
        let data = output.value
        let status = process.isRunning ? -1 : process.terminationStatus
        var error = String(decoding: data.err, as: UTF8.self)
        if timedOut { error = "Timed out after \(Int(timeout)) seconds. " + error }
        return Result(status: timedOut ? -1 : status, output: String(decoding: data.out, as: UTF8.self), error: error)
    }
}
