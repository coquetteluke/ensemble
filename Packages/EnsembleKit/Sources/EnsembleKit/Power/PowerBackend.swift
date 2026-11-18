import Foundation

/// The platform calls `PowerController` needs. The Mac app supplies the real one (IOKit assertions,
/// `pmset`, `sudo -n`, `osascript`); tests use a fake.
///
/// Every method is synchronous and may block (some run a process). The controller calls the slow ones
/// off the main actor, except at quit, where it must finish before the app exits.
public protocol PowerBackend: Sendable {
    /// Takes power assertions that prevent idle system sleep and idle display sleep. Returns false if
    /// they could not be created. Calling it while already held keeps the existing assertions.
    func holdAwake(reason: String) -> Bool
    /// Releases the assertions taken by `holdAwake`. Safe to call when none are held.
    func releaseAwake()

    /// `SleepDisabled` from `pmset -g`: true for 1, false for 0, nil if it could not be read.
    func readSleepDisabled() -> Bool?
    /// Runs `sudo -n /usr/bin/pmset disablesleep 1` (or 0).
    func setSleepDisabled(_ disabled: Bool) -> PowerCommandResult
    /// Whether `sudo -n` may run `pmset disablesleep` without a password.
    func sudoRuleStatus() -> SudoRuleStatus
    /// Installs the sudoers rule through the macOS administrator password dialog.
    func installSudoRule() -> PowerSetupResult

    /// True on Macs with a built-in lid (the IORegistry has `AppleClamshellState`).
    func hasLid() -> Bool
    /// True while running on battery power.
    func isOnBattery() -> Bool
    /// True while another tool that wants lid lock on is running (Luke's `lidlock` keeps a
    /// `caffeinate` whose pid is in `~/.local/share/lidlock/awake.pid` while it is on).
    func externalLidLockToolActive() -> Bool
}
