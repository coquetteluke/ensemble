import Foundation

/// The environment and command for a terminal tab's shell: the user's login shell with a plain environment, the
/// way a new Terminal window starts. Nothing from Ensemble's own environment is passed on except a short list of
/// the user's own settings (home, user, temporary folder, SSH agent, language), so passwords and tokens Ensemble
/// was started with (for example `OPENCODE_SERVER_PASSWORD`) never reach the shell. The login shell sets up
/// `PATH` and the rest from the user's profile files.
public enum TerminalEnvironment {
    /// Variables taken from Ensemble's environment when set. Everything else is left out.
    public static let passedThrough: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_COLLATE", "LC_MESSAGES", "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
    ]

    /// The system's default `PATH`; `/etc/zprofile` (or the shell's equivalent) extends it at login.
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The environment for a shell. `source` is Ensemble's own environment; `home`, `user` and `shell` come from
    /// the user database; `localeIdentifier` (like `en_GB`) sets `LANG` when no UTF-8 locale is set.
    public static func make(from source: [String: String], home: String, user: String, shell: String,
                            localeIdentifier: String?) -> [String: String] {
        var environment = source.filter { passedThrough.contains($0.key) }
        environment["HOME"] = home
        environment["USER"] = user
        environment["LOGNAME"] = user
        environment["SHELL"] = shell
        environment["PATH"] = defaultPath
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["ENSEMBLE_TERMINAL"] = "1"
        let localeSet = ["LC_ALL", "LC_CTYPE", "LANG"].contains { environment[$0]?.uppercased().contains("UTF-8") == true }
        if !localeSet {
            environment["LANG"] = Self.utf8Locale(localeIdentifier)
        }
        return environment
    }

    /// `en_GB.UTF-8` for `en_GB` (region and language only), `en_US.UTF-8` when the identifier is unusable.
    static func utf8Locale(_ identifier: String?) -> String {
        let base = (identifier ?? "").split(separator: "@").first.map(String.init) ?? ""
        let valid = base.range(of: "^[a-z]{2,3}_[A-Z]{2}$", options: .regularExpression) != nil
        return (valid ? base : "en_US") + ".UTF-8"
    }

    #if os(macOS)
    /// The user's login shell, home folder and name from the user database (not from `$SHELL`, which an app
    /// started from the Dock may not have).
    public static func currentUser() -> (shell: String, home: String, name: String) {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var home = NSHomeDirectory()
        var name = NSUserName()
        if getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0, result != nil {
            if let pointer = record.pw_shell { shell = String(cString: pointer) }
            if let pointer = record.pw_dir { home = String(cString: pointer) }
            if let pointer = record.pw_name { name = String(cString: pointer) }
        }
        if !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/zsh" }
        return (shell, home, name)
    }

    /// Everything needed to start the user's login shell (`$SHELL -l`) in `directory`.
    public static func loginShell(in directory: String, columns: Int, rows: Int) -> PseudoTerminal.Configuration {
        let user = currentUser()
        let environment = make(from: ProcessInfo.processInfo.environment, home: user.home, user: user.name, shell: user.shell,
                               localeIdentifier: Locale.current.identifier)
        var isDirectory: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
            ? directory : user.home
        return PseudoTerminal.Configuration(executable: user.shell, arguments: [(user.shell as NSString).lastPathComponent, "-l"],
                                            environment: environment, directory: folder, columns: columns, rows: rows)
    }
    #endif
}
