import Foundation

/// The fixed rules of the safety check for Auto (`SafetyCheck.swift`). A prompt they cover asks before any model call,
/// and no model answer can change that. The lists live in `PermissionRules` (`safetyCheck*`).
///
/// What always asks:
/// - every prompt that is not a shell command or a fetch from this Mac: edits that still prompt in Auto (protected build
///   files, dot paths, OpenCode's config shape), `.env` reads, work outside the project, web searches, other tools;
/// - shell commands that run git, change system settings, reach other computers, fetch from the internet, erase disks,
///   stop programs, run as another user, delete folders (`rm -r`), publish packages, install software or packages,
///   run downloaded packages (`npx`), pipe into a shell, or run text as a command;
/// - commands that name anything outside the project folder (`~`, `$HOME`, absolute paths, `..` past the folder, links
///   in the folder that point out of it), a path with a segment that starts with a dot (except build output folders), a
///   protected file name in any case, agent instruction files, key files, or a top-level name of OpenCode's config shape;
/// - commands whose words the reader cannot know: command and process substitution, ANSI-C quoting (`$'...'`), brace
///   expansion, wildcards outside quotes, and program names built with quotes, escapes, variables or wildcards;
/// - commands that move the working folder in ways the rules cannot follow (`cd` alone, `cd -`, `pushd`, `popd`,
///   targets with variables or wildcards), set variables that change what runs or where it connects (`PATH`,
///   `DYLD_*`, `*_PROXY`, ...), give an interpreter code inline (`python -c`, `node -e`, here-documents), or hand a
///   command line to a wrapper flag (`env -S`, `tar --to-command`);
/// - commands with hidden characters, and commands longer than `PermissionRules.safetyCheckCommandLimit`.
///
/// Fetches to this Mac go to the model only with a short list of flags that cannot change where the request goes.
public enum SafetyCheckHardRules {
    static let outside = "Outside the project folder"
    static let hidden = "Hidden files and folders always ask"
    static let protected = "Protected build or config file"

    /// Why the prompt must be left for the user without asking the model, or nil when the model may decide.
    public static func reasonToAsk(_ query: SafetyCheckQuery) -> String? {
        switch query.action {
        case "shell", "bash":
            var texts = query.resources.filter { !$0.isEmpty }
            if let command = query.command, !command.isEmpty { texts.insert(command, at: 0) }
            guard !texts.isEmpty else { return "No command to check" }
            for text in texts {
                if let reason = shellReason(text, directory: query.directory) { return reason }
            }
            return nil
        case "webfetch":
            let addresses = (query.resources + [query.command].compactMap { $0 }).filter { !$0.isEmpty }
            guard !addresses.isEmpty else { return "No address to check" }
            return addresses.allSatisfy(isLoopbackAddress) ? nil : "Network access always asks"
        case "edit", "write", "patch":
            return editReason(query.resources, directory: query.directory)
        case "read":
            return "Reading this file always asks"
        case "external_directory":
            return outside
        case "websearch":
            return "Web searches always ask"
        default:
            return "Only commands are checked"
        }
    }

    // MARK: Shell

    /// Why a shell command line always asks, or nil.
    static func shellReason(_ command: String, directory: String) -> String? {
        if command.count > PermissionRules.safetyCheckCommandLimit { return "Too long to check" }
        if PermissionDisplay.visible(command) != command { return "Contains hidden characters" }
        let reading = ShellText.read(command)
        // Forms whose result the reader cannot know (ANSI-C quoting, command and process substitution) could become
        // any program, so they ask whatever they hold.
        if let problem = reading.problem { return problem }
        for segment in reading.segments {
            if let reason = segmentReason(segment, directory: directory) { return reason }
        }
        return nil
    }

    static func segmentReason(_ segment: ShellSegment, directory: String) -> String? {
        let words = segment.words
        let programs = programIndices(segment)
        for raw in segment.raw where isAssignment(raw) {
            if let reason = sensitiveVariableReason(raw) { return reason }
        }
        if segment.afterPipe, let first = programs.first, PermissionRules.safetyCheckInterpreters.contains(programName(words[first])) {
            return "Pipes text into a shell"
        }
        for index in programs {
            // A program word built with quotes, escapes, variables or wildcards (`c\url`, `"git"`, `$X`, `/usr/bin/cur?`)
            // may run something other than what it reads as, so no list lookup on it can be trusted.
            guard isLiteralProgram(segment.raw[index]) else { return "The program name is not plain text" }
            let program = programName(words[index])
            if let reason = directoryChangeReason(program: program, arguments: Array(segment.raw[(index + 1)...])) { return reason }
            if wrapperRunsText(program: program, arguments: Array(words[(index + 1)...])) { return "Runs text as a command" }
            if let reason = commandFlagReason(program: program, arguments: Array(words[(index + 1)...])) { return reason }
            let original = Array(words[(index + 1)...])
            let rest = original.map { $0.lowercased() }
            if let reason = PermissionRules.safetyCheckAskPrograms[program] { return reason }
            for (prefix, reason) in PermissionRules.safetyCheckAskProgramPrefixes where program.hasPrefix(prefix) { return reason }
            if program == "env", printsEnvironment(rest) { return "Prints environment variables, which can hold secrets" }
            if let reason = PermissionRules.safetyCheckRecursiveAskPrograms[program], hasRecursiveFlag(rest) { return reason }
            if PermissionRules.safetyCheckFetchPrograms.contains(program) {
                // A variable set for the fetch (`http_proxy=`, `CURL_HOME=`) can send it elsewhere.
                if segment.raw[..<index].contains(where: isAssignment) { return "Fetches from the internet" }
                if !fetchesOnlyThisMac(original) { return "Fetches from the internet" }
            }
            if PermissionRules.safetyCheckInterpreters.contains(program), runsInlineCode(program: program, original) {
                return "Runs code written into the command"
            }
            for (pattern, reason) in PermissionRules.safetyCheckAskCommands where matches(pattern, program: program, rest: rest) {
                return reason
            }
            if let reason = installReason(program: program, rest: rest) { return reason }
        }
        let programSet = Set(programs)
        for (index, word) in words.enumerated() {
            if let reason = wordReason(word, directory: directory, isProgram: programSet.contains(index)) { return reason }
            // Quoted text is also read piece by piece, so a path, address or name inside a string still counts.
            let pieces = word.split(whereSeparator: { " \t\n;|&()<>'\"".contains($0) }).map(String.init)
            if pieces.count > 1 || pieces.first != word {
                for piece in pieces {
                    if let reason = wordReason(piece, directory: directory, isProgram: false) { return reason }
                }
            }
        }
        return nil
    }

    /// Programs that run a command given in a flag or in their own script text (`tar --to-command`, `awk` with
    /// `system`), and `env -C`/`--chdir` with a folder the rules cannot follow.
    static func commandFlagReason(program: String, arguments: [String]) -> String? {
        if let flags = PermissionRules.safetyCheckCommandFlags[program] {
            for word in arguments {
                let name = word.hasPrefix("--") ? (word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word) : word
                if flags.contains(name) { return "Runs text as a command" }
                if !word.hasPrefix("--"), flags.contains(where: { !$0.hasPrefix("--") && word.hasPrefix($0) && $0.count > 1 }) {
                    return "Runs text as a command"
                }
            }
        }
        if ["awk", "gawk", "nawk", "mawk"].contains(program),
           arguments.contains(where: { $0.contains("system") || $0.contains("getline") }) {
            return "Runs text as a command"
        }
        if program == "env" {
            for (offset, word) in arguments.enumerated() {
                let value: String? = if word == "-C" || word == "--chdir" {
                    offset + 1 < arguments.count ? arguments[offset + 1] : nil
                } else if word.hasPrefix("--chdir=") {
                    String(word.dropFirst("--chdir=".count))
                } else if word.hasPrefix("-C"), word.count > 2 {
                    String(word.dropFirst(2))
                } else {
                    nil
                }
                if let value, value.contains(where: { "$`{}*?[]~".contains($0) }) { return outside }
            }
        }
        return nil
    }

    /// A change of working folder the rules cannot follow asks: later relative paths would be read against the wrong
    /// folder. `cd` alone (home), `cd -` (the previous folder), `pushd`, `popd`, and a target with a variable, braces,
    /// wildcards or `~`. Other targets are paths like any other (`cd /tmp` and `cd ..` are outside), and paths after a
    /// `cd` into a subfolder are read against the session's folder, which can only make them look further out.
    static func directoryChangeReason(program: String, arguments: [String]) -> String? {
        if program == "pushd" || program == "popd" { return outside }
        guard program == "cd" || program == "chdir" else { return nil }
        let targets = arguments.filter { !["-P", "-L", "-e", "-@", "--"].contains($0) }
        guard let target = targets.first else { return outside }
        if target == "-" { return outside }
        if target.contains(where: { "$`{}*?[]~".contains($0) }) { return outside }
        return nil
    }

    /// Plain program text: no quotes, backslashes, variables, wildcards, braces or `~`. The test builtins `[` and `[[`
    /// count as plain.
    static func isLiteralProgram(_ raw: String) -> Bool {
        if raw == "[" || raw == "[[" { return true }
        return !raw.contains { "'\"\\$*?[]{}~`".contains($0) }
    }

    /// Variables that change which programs run, what they load at start, or where they connect.
    static func sensitiveVariableReason(_ assignment: String) -> String? {
        guard let equals = assignment.firstIndex(of: "=") else { return nil }
        let name = String(assignment[..<equals])
        let upper = name.uppercased()
        if PermissionRules.safetyCheckSensitiveVariables.contains(upper)
            || PermissionRules.safetyCheckSensitiveVariablePrefixes.contains(where: { upper.hasPrefix($0) })
            || upper.hasSuffix("_PROXY") {
            return "Changes how programs start or connect"
        }
        return nil
    }

    /// True when an interpreter gets code written into the command instead of a file: its inline-code flag (`python -c`,
    /// `bash -lc`, `node -e`, `perl -pe`, `php -r`, also inside a cluster of short flags), `-` (code from the input),
    /// or `eval` (`deno eval`). Word scanning cannot see through code (`exec(bytes.fromhex(...))`). Here-documents make the
    /// whole line uncheckable (`ShellText`).
    static func runsInlineCode(program: String, _ arguments: [String]) -> Bool {
        let flags = PermissionRules.safetyCheckInlineCodeFlags[program] ?? []
        for word in arguments {
            if word == "-" || word.lowercased() == "eval" { return true }
            guard word.hasPrefix("-") else { break }
            if word.hasPrefix("--") {
                let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
                if flags.contains(name) { return true }
                continue
            }
            // `-lc`, `-pe`, `-Bc`: any short letter that is an inline-code flag.
            if word.dropFirst().contains(where: { flags.contains("-" + String($0)) }) { return true }
        }
        return false
    }

    // MARK: Programs

    /// Words that only lead into the command (`{`, `!`, `then`, ...).
    static let prefixWords: Set<String> = ["{", "}", "!", "then", "do", "done", "else", "elif", "if", "fi", "while", "until"]

    /// Programs that run the next program (`env FOO=1 git status`, `xargs rm`, `time -p make`).
    static let wrappers: Set<String> = [
        "env", "nohup", "nice", "time", "timeout", "gtimeout", "command", "builtin", "exec", "xargs", "sudo", "doas",
        "caffeinate", "stdbuf", "gstdbuf", "unbuffer", "chronic", "ionice", "taskset", "arch", "noglob",
    ]

    /// Wrapper flags that take the next word as their value. None of these values is a command: a flag whose value is
    /// a command (`env -S`, `--split-string`) is never skipped, it asks (`wrapperRunsText`).
    static let wrapperValueFlags: [String: Set<String>] = [
        "xargs": ["-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s", "-d", "-E", "-e", "-a", "--arg-file", "--delimiter",
                  "--max-args", "--max-procs", "--max-lines", "--replace"],
        "nice": ["-n", "--adjustment"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"], "gtimeout": ["-s", "-k", "--signal", "--kill-after"],
        "sudo": ["-u", "-g", "-U", "-C", "-h", "-p", "-r", "-t", "-D"], "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-P", "-a", "--unset", "--chdir", "--argv0"],
        "caffeinate": ["-t", "-w"], "ionice": ["-c", "-n", "--class", "--classdata"], "arch": ["-arch"],
        "exec": ["-a"], "time": ["-o", "-f", "--output", "--format"], "stdbuf": ["-i", "-o", "-e"], "gstdbuf": ["-i", "-o", "-e"],
    ]

    /// Wrapper flags known to take no value. Any other flag might take one, so the command is read both ways.
    static let wrapperBooleanFlags: [String: Set<String>] = [
        "xargs": ["-0", "-r", "-t", "-p", "-x", "-o", "--null", "--no-run-if-empty", "--verbose", "--interactive", "--exit",
                  "--open-tty"],
        "env": ["-i", "-0", "-v", "--ignore-environment", "--null", "--debug"],
        "timeout": ["-v", "--foreground", "--preserve-status", "--verbose"],
        "gtimeout": ["-v", "--foreground", "--preserve-status", "--verbose"],
        "time": ["-p", "-l", "-v", "-a", "--portability", "--verbose", "--append"],
        "command": ["-p"], "exec": ["-c", "-l"], "caffeinate": ["-d", "-i", "-m", "-s", "-u"], "ionice": ["-t"],
        "arch": ["-x86_64", "-arm64", "-arm64e", "-i386"], "unbuffer": ["-p"],
    ]

    /// Wrappers whose first plain word is a value, not the program (`timeout 30 npm test`, `taskset 3 make`).
    static let wrapperPositionals: [String: Int] = ["timeout": 1, "gtimeout": 1, "taskset": 1]

    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh"]

    /// Indices of the words that are programs: the first one, the ones wrappers run, the command after `sh -c`, and the
    /// commands `find -exec` runs.
    static func programIndices(_ segment: ShellSegment) -> [Int] {
        let words = segment.words
        var result = Set<Int>()
        var starts = [0]
        for (index, word) in words.enumerated() where index + 1 < words.count {
            let lower = word.lowercased()
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(lower) { starts.append(index + 1) }
            // `sh -c`, `bash -lc`, `zsh -ec`: the text after it is a command.
            if lower.hasPrefix("-"), !lower.hasPrefix("--"), lower.hasSuffix("c"), index > 0,
               shells.contains(programName(words[index - 1])) || shells.contains(programName(words[0])) {
                starts.append(index + 1)
            }
        }
        var memo: [Int: Set<Int>] = [:]
        for start in starts {
            result.formUnion(programChain(segment, from: start, memo: &memo))
        }
        return result.sorted()
    }

    /// The program at `start` and every program the wrappers before it run. A word counts as an assignment
    /// (`NAME=value`, skipped) only when its name is written plainly; `"X=1" curl` runs a program named `X=1`.
    /// After a wrapper flag that is not known to take a value or not, the command is read both ways (the next word as
    /// the program, and as the flag's value), so an unknown value flag cannot hide the program.
    static func programChain(_ segment: ShellSegment, from start: Int, memo: inout [Int: Set<Int>]) -> Set<Int> {
        if let known = memo[start] { return known }
        memo[start] = []
        let words = segment.words
        let raw = segment.raw
        let count = words.count
        var result = Set<Int>()
        var index = start
        while index < count, isAssignment(raw[index]) || prefixWords.contains(raw[index]) { index += 1 }
        guard index < count else { return result }
        let program = programName(words[index])
        result.insert(index)
        if wrappers.contains(program) {
            let valueFlags = wrapperValueFlags[program] ?? []
            let booleanFlags = wrapperBooleanFlags[program] ?? []
            index += 1
            while index < count {
                let word = words[index]
                if word == "--" { index += 1; break }
                if word.hasPrefix("-"), word.count > 1 {
                    if valueFlags.contains(word) {
                        index += 2
                        continue
                    }
                    let attached = word.hasPrefix("--") ? word.contains("=") : valueFlags.contains(String(word.prefix(2)))
                    if !booleanFlags.contains(word), !attached, index + 2 <= count {
                        result.formUnion(programChain(segment, from: index + 2, memo: &memo))
                    }
                    index += 1
                    continue
                }
                if program == "env", isAssignment(raw[index]) { index += 1; continue }
                break
            }
            index += wrapperPositionals[program] ?? 0
            result.formUnion(programChain(segment, from: index, memo: &memo))
        }
        memo[start] = result
        return result
    }

    /// Wrapper flags whose value is itself a command line: `env -S 'curl x'`, `env --split-string='rm -rf ~'`, and short
    /// clusters that include it (`env -iS`).
    static func wrapperRunsText(program: String, arguments: [String]) -> Bool {
        guard program == "env" else { return false }
        let valueFlags = wrapperValueFlags["env"] ?? []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word == "--" { break }
            guard word.hasPrefix("-"), word.count > 1 else {
                if isAssignment(word) { continue }
                break
            }
            if word.hasPrefix("--split-string") || word == "--split" { return true }
            if !word.hasPrefix("--"), word.dropFirst().contains("S") { return true }
            if valueFlags.contains(word) { index += 1 }
        }
        return false
    }

    /// The program's name: the last path component, lower-cased.
    static func programName(_ word: String) -> String {
        let name = word.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? word
        return name.lowercased()
    }

    /// `NAME=value`.
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// `env` with nothing to run prints every variable.
    static func printsEnvironment(_ rest: [String]) -> Bool {
        !rest.contains { !$0.hasPrefix("-") && !isAssignment($0) }
    }

    /// `-r`, `-R`, `-rf`, `-fR`, `--recursive`.
    static func hasRecursiveFlag(_ rest: [String]) -> Bool {
        rest.contains { word in
            if word == "--recursive" { return true }
            guard word.hasPrefix("-"), !word.hasPrefix("--") else { return false }
            return word.dropFirst().contains { $0 == "r" }
        }
    }

    /// True when `pattern` (`"npm publish"`) is this program followed by its other words, in order.
    static func matches(_ pattern: String, program: String, rest: [String]) -> Bool {
        let tokens = pattern.split(separator: " ").map(String.init)
        guard tokens.first == program else { return false }
        return lastMatch(of: tokens.dropFirst(), in: rest) != nil
    }

    /// Where the last of `tokens` sits in `rest` when they all appear in order, else nil. Nil-free for an empty list (-1).
    static func lastMatch(of tokens: ArraySlice<String>, in rest: [String]) -> Int? {
        var position = -1
        for token in tokens {
            guard let found = rest[(position + 1)...].firstIndex(of: token) else { return nil }
            position = found
        }
        return position
    }

    /// Installing a named package (downloaded from the internet) or installing for the whole Mac asks; installing what
    /// the project declares (only flags and local paths) is left to the model.
    static func installReason(program: String, rest: [String]) -> String? {
        for pattern in PermissionRules.safetyCheckInstallCommands {
            let tokens = pattern.split(separator: " ").map(String.init)
            guard tokens.first == program, let last = lastMatch(of: tokens.dropFirst(), in: rest) else { continue }
            var skipNext = false
            for word in rest[(last + 1)...] {
                if skipNext { skipNext = false; continue }
                if word == "-g" || word == "--global" || word.hasPrefix("--location=global") || word == "--user" {
                    return "Installs a package for the whole Mac"
                }
                if word.hasPrefix("-") {
                    if PermissionRules.safetyCheckInstallValueFlags.contains(word) { skipNext = true }
                    continue
                }
                if isLocalPackagePath(word) { continue }
                return "Installs a package from the internet"
            }
        }
        return nil
    }

    /// `.`, `./x`, `../x`, `/abs`, `file:x` or a local archive: not a download (paths are checked on their own).
    static func isLocalPackagePath(_ word: String) -> Bool {
        word.hasPrefix(".") || word.hasPrefix("/") || word.hasPrefix("file:")
            || [".tgz", ".tar.gz", ".whl", ".zip"].contains { word.hasSuffix($0) }
    }

    /// True when the fetch can only reach this Mac: it names at least one address, every plain word is a loopback
    /// address, and every flag is on a short list that cannot change where the request goes or read settings from a
    /// file (`PermissionRules.safetyCheckFetchSafeFlags`, `...FetchValueFlags`). Any other flag asks: `-x`/`--proxy`,
    /// `--preproxy`, `--socks5`, `--resolve`, `--connect-to`, `-K`/`--config`, `-L` (a local server could redirect the
    /// request), `-e`, attached forms such as `-xhttp://host`, and every flag not listed. Values of the listed value
    /// flags are checked too (an HTTP method, a number, or an output file that is not an address). Case matters: `-x`
    /// (proxy) and `-X` (method) differ.
    static func fetchesOnlyThisMac(_ arguments: [String]) -> Bool {
        var addresses = 0
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if !optionsEnded, word == "--" {
                optionsEnded = true
                continue
            }
            if !optionsEnded, word.hasPrefix("-"), word.count > 1 {
                if isSafeFetchFlag(word) { continue }
                var flag = word
                var value: String?
                if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
                    flag = String(word[..<equals])
                    value = String(word[word.index(after: equals)...])
                }
                guard let kind = PermissionRules.safetyCheckFetchValueFlags[flag] else { return false }
                if value == nil {
                    guard index < arguments.count else { return false }
                    value = arguments[index]
                    index += 1
                }
                guard let value, isSafeFetchValue(value, kind: kind) else { return false }
                continue
            }
            guard isLoopbackAddress(word) else { return false }
            addresses += 1
        }
        return addresses > 0
    }

    /// A listed boolean flag, or a cluster of listed short letters (`-sS`, `-fsS`).
    static func isSafeFetchFlag(_ word: String) -> Bool {
        if PermissionRules.safetyCheckFetchSafeFlags.contains(word) { return true }
        guard !word.hasPrefix("--"), word.count > 1 else { return false }
        return word.dropFirst().allSatisfy { PermissionRules.safetyCheckFetchSafeLetters.contains($0) }
    }

    static func isSafeFetchValue(_ value: String, kind: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("://"), !value.contains("@") else { return false }
        switch kind {
        case "method":
            return ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(value)
        case "number":
            return !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        case "file":
            // A file the response is saved to; the word is also checked as a path with the rest of the command.
            return !isLoopbackAddress(value) && !value.contains(":")
        default:
            return false
        }
    }

    // MARK: Words

    /// Paths, names and addresses in one word (and in the value of `--flag=value` or `NAME=value`).
    static func wordReason(_ word: String, directory: String, isProgram: Bool) -> String? {
        var candidates = [word]
        if !isProgram, let equals = word.firstIndex(of: "=") {
            candidates.append(String(word[word.index(after: equals)...]))
        }
        for candidate in candidates where !candidate.isEmpty {
            if candidate.contains("://") {
                if !isLoopbackAddress(candidate) { return "Network access always asks" }
                continue
            }
            if let reason = pathReason(candidate, directory: directory, isProgram: isProgram) { return reason }
            if !isProgram, let reason = nameReason(candidate) { return reason }
        }
        return nil
    }

    /// Variables that point outside the project.
    static let outsideVariables = ["$HOME", "${HOME", "$TMPDIR", "${TMPDIR", "$OLDPWD", "${OLDPWD", "$XDG_", "${XDG_", "$USER", "${USER"]

    static func pathReason(_ text: String, directory: String, isProgram: Bool) -> String? {
        // `~` is the home folder at the start of a word and after `:` or `=`; any `~` counts.
        if text.contains("~") { return outside }
        if outsideVariables.contains(where: { text.contains($0) }) { return outside }
        // Other variables and regular expressions (`/^#/d`) cannot be resolved here; the model sees them.
        if text.contains("$") || text.contains("^") { return nil }
        guard text.hasPrefix("/") || text.hasPrefix(".") || text.contains("/") else {
            // A plain name can still be a link in the folder that points out of it (`cd docs`).
            return !text.hasPrefix("-") && leavesFolderOnDisk(directory + "/" + text, root: directory) ? outside : nil
        }
        if text.hasPrefix("/") {
            if PermissionRules.safetyCheckSystemPathsAllowed.contains(text) || text.hasPrefix("/dev/fd/") { return nil }
            if isProgram, PermissionRules.safetyCheckSystemProgramFolders.contains(where: { folder in
                text.hasPrefix(folder) && !text.dropFirst(folder.count).contains("/")
            }) { return nil }
        }
        let root = normalized(directory)
        let resolved = normalized(text.hasPrefix("/") ? text : directory + "/" + text)
        guard resolved == root || resolved.hasPrefix(root == "/" ? "/" : root + "/") else { return outside }
        // A link inside the folder can point out of it (a cloned repository's `docs -> /Users/me`).
        if leavesFolderOnDisk(text.hasPrefix("/") ? text : directory + "/" + text, root: directory) { return outside }
        let relative = resolved == root ? "" : String(resolved.dropFirst(root == "/" ? 1 : root.count + 1))
        if isProgram, PermissionRules.safetyCheckProgramFoldersAllowed.contains(where: { relative.hasPrefix($0) }) { return nil }
        for part in relative.split(separator: "/") where part.hasPrefix(".") {
            if PermissionRules.safetyCheckDotFoldersAllowed.contains(String(part)) { continue }
            // `...` (Go's package pattern) and other all-dot names are not configuration anything reads.
            if part.allSatisfy({ $0 == "." }) { continue }
            return hidden
        }
        return nil
    }

    /// Protected names in any case, and OpenCode's config shape at the top of the folder.
    static func nameReason(_ text: String) -> String? {
        let base = (text.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? text).lowercased()
        guard !base.isEmpty else { return nil }
        if protectedNamePatterns.contains(where: { globMatch($0, base) }) { return protected }
        let topLevel = !text.contains("/") || text.hasPrefix("./") && !text.dropFirst(2).contains("/")
        if topLevel, isConfigShape(base), !PermissionRules.configLookalikesAllowed.contains(base) {
            return "Could be OpenCode's config file"
        }
        return nil
    }

    static let protectedNamePatterns: [String] = (PermissionRules.protectedFileNames + PermissionRules.safetyCheckProtectedNames)
        .map { $0.lowercased() }

    /// `*.ext`, `prefix*` and exact names.
    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        if pattern.hasPrefix("*") { return name.hasSuffix(pattern.dropFirst()) }
        if pattern.hasSuffix("*") { return name.hasPrefix(pattern.dropLast()) }
        return name == pattern
    }

    /// Eight characters, a dot, then four or five (`opencode.json`, `opencode.jsonc` in any spelling).
    static func isConfigShape(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 13 || scalars.count == 14, scalars[8] == "." else { return false }
        return !scalars[..<8].contains(".") && !scalars[9...].contains(".")
    }

    /// The path with `.` and `..` resolved, without a trailing slash, lower-cased (Mac disks ignore case), and with
    /// `/private` removed before `/tmp`, `/var` and `/etc` (the same folders).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        var result = "/" + parts.joined(separator: "/")
        for folder in ["/private/tmp", "/private/var", "/private/etc"] where result == folder || result.hasPrefix(folder + "/") {
            result = String(result.dropFirst("/private".count))
        }
        return result.lowercased()
    }

    /// True when the nearest existing part of `path` below `root` resolves, through links, to somewhere outside it.
    static func leavesFolderOnDisk(_ path: String, root: String) -> Bool {
        let fileManager = FileManager.default
        let rootPath = lexical(root)
        var probe = lexical(path)
        while probe.count > rootPath.count, !fileManager.fileExists(atPath: probe) {
            probe = (probe as NSString).deletingLastPathComponent
        }
        guard probe.count > rootPath.count else { return false }
        let real = normalized(URL(fileURLWithPath: probe).resolvingSymlinksInPath().path)
        let realRoot = normalized(URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path)
        return !(real == realRoot || real.hasPrefix(realRoot == "/" ? "/" : realRoot + "/"))
    }

    /// The path with `.` and `..` resolved and no trailing slash, case kept.
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: Edits and addresses

    static func editReason(_ paths: [String], directory: String) -> String {
        for path in paths where !path.isEmpty {
            if path.hasPrefix("~") { return outside }
            let root = normalized(directory)
            let resolved = normalized(path.hasPrefix("/") ? path : directory + "/" + path)
            guard resolved == root || resolved.hasPrefix(root + "/") else { return outside }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) { return hidden }
        }
        return protected
    }

    /// `http://localhost:3000/x`, `127.0.0.1:8080`, `[::1]`, `0.0.0.0`, `app.localhost`.
    public static func isLoopbackAddress(_ text: String) -> Bool {
        var host: String
        if text.contains("://") {
            guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
                  ["http", "https", "ws", "wss"].contains(scheme), let parsed = components.host else { return false }
            host = parsed
        } else {
            var rest = Substring(text)
            if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
            if rest.contains("@") { return false }
            if rest.hasPrefix("[") {
                guard let close = rest.firstIndex(of: "]") else { return false }
                host = String(rest[rest.index(after: rest.startIndex)..<close])
            } else if let colon = rest.firstIndex(of: ":") {
                host = String(rest[..<colon])
            } else {
                host = String(rest)
            }
        }
        host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy(\.isASCII) && octet.allSatisfy(\.isNumber) && (Int(octet) ?? 256) < 256
        }
    }
}

/// One simple command of a line: its words in order (as read, and as written), and whether a pipe feeds it.
struct ShellSegment: Hashable, Sendable {
    /// Each word with its quotes removed.
    var words: [String]
    /// Each word exactly as written (quotes and `$` kept), for telling plain words from quoted or built ones.
    var raw: [String]
    var afterPipe: Bool

    init(words: [String], raw: [String]? = nil, afterPipe: Bool) {
        self.words = words
        self.raw = raw ?? words
        self.afterPipe = afterPipe
    }
}

/// What the reader found in a command line.
struct ShellReading: Hashable, Sendable {
    var segments: [ShellSegment]
    /// Set when the line is not checkable: it uses something outside the reader's allowlist. The line then always asks
    /// and never reaches the model.
    var problem: String?
}

/// The shell reader for the hard rules. It is an allowlist: a line is checkable only when every character is one the
/// reader fully understands, so what it reads is exactly what the shell will run.
///
/// Understood:
/// - plain words: letters, digits and `-_./=:,+@%~` (a `~` anywhere makes the word count as outside the folder);
/// - single quotes (anything inside is literal), and double quotes holding no backtick, no backslash and no `$` other
///   than a plain variable;
/// - plain variables, `$NAME` and `${NAME}` (a name only, with its closing brace);
/// - separators `;`, `&&`, `||`, `|`, `|&`, `&` (background), newlines, and `(` `)` for subshells;
/// - redirections `>`, `>>`, `<`, `>|`, `2>&1`, `&>`, `&>>`, `<&`.
///
/// Everything else makes the line uncheckable: command substitution (`$(...)`, backticks, also inside `${...}`),
/// process substitution (`<(...)`, `>(...)`), here-documents and here-strings, `${...}` with anything beyond a name or
/// with no closing brace, ANSI-C and locale quoting (`$'...'`, `$"..."`), special parameters (`$?`, `$1`), unquoted
/// wildcards and braces (`*`, `?`, `[`, `{`, `}`), backslashes outside single quotes, a quote that is not closed, and any
/// other character (`#`, `!`, `^`, ...).
enum ShellText {
    static func segments(_ text: String) -> [ShellSegment] { read(text).segments }

    static let substitution = "Runs a command inside another command"
    static let expansion = "Uses shell expansion the check cannot read"

    static func read(_ text: String) -> ShellReading {
        var segments: [ShellSegment] = []
        var words: [String] = []
        var raws: [String] = []
        var word = String.UnicodeScalarView()
        var raw = String.UnicodeScalarView()
        var inWord = false
        var afterPipe = false

        func endWord() {
            if inWord {
                words.append(String(word))
                raws.append(String(raw))
            }
            word = String.UnicodeScalarView()
            raw = String.UnicodeScalarView()
            inWord = false
        }
        func endSegment(nextAfterPipe: Bool) {
            endWord()
            if !raws.isEmpty { segments.append(ShellSegment(words: words, raw: raws, afterPipe: afterPipe)) }
            words = []
            raws = []
            afterPipe = nextAfterPipe
        }
        func fail(_ reason: String) -> ShellReading {
            ShellReading(segments: segments, problem: reason)
        }

        let scalars = Array(text.unicodeScalars)
        var index = 0
        func next(_ offset: Int = 1) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }
        /// The length of a plain variable at `position` (`$NAME` or `${NAME}`), or nil.
        func plainVariable(at position: Int) -> Int? {
            guard position + 1 < scalars.count else { return nil }
            func isNameStart(_ scalar: Unicode.Scalar) -> Bool { scalar == "_" || (scalar.isASCII && CharacterSet.letters.contains(scalar)) }
            func isName(_ scalar: Unicode.Scalar) -> Bool { scalar == "_" || (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) }
            if scalars[position + 1] == "{" {
                var end = position + 2
                guard end < scalars.count, isNameStart(scalars[end]) else { return nil }
                while end < scalars.count, isName(scalars[end]) { end += 1 }
                guard end < scalars.count, scalars[end] == "}" else { return nil }
                return end + 1 - position
            }
            guard isNameStart(scalars[position + 1]) else { return nil }
            var end = position + 2
            while end < scalars.count, isName(scalars[end]) { end += 1 }
            return end - position
        }
        /// Why a `$` at `position` that is not a plain variable makes the line uncheckable.
        func dollarProblem(at position: Int) -> String {
            let following = position + 1 < scalars.count ? scalars[position + 1] : nil
            if following == "(" { return substitution }
            if following == "'" || following == "\"" { return "Uses shell quoting the check cannot read" }
            if following == "{" {
                // `${x:-$(cmd)}`, `${x:-`cmd`}`: a command inside the expansion.
                var end = position + 2
                while end < scalars.count, scalars[end] != "}" {
                    if scalars[end] == "`" || (scalars[end] == "$" && end + 1 < scalars.count && scalars[end + 1] == "(") {
                        return substitution
                    }
                    end += 1
                }
            }
            return expansion
        }
        func isPlain(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || "-_./=:,+@%~".unicodeScalars.contains(scalar)
        }
        func appendVariable(_ length: Int) {
            for offset in 0..<length {
                word.append(scalars[index + offset])
                raw.append(scalars[index + offset])
            }
            inWord = true
            index += length
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case " ", "\t":
                endWord()
            case "\n", ";", "(", ")":
                endSegment(nextAfterPipe: false)
            case "|":
                if next() == "|" {
                    index += 1
                    endSegment(nextAfterPipe: false)
                } else {
                    if next() == "&" { index += 1 }
                    endSegment(nextAfterPipe: true)
                }
            case "&":
                if next() == "&" {
                    index += 1
                    endSegment(nextAfterPipe: false)
                } else if next() == ">" {
                    endWord()
                    index += 1
                    if next() == ">" { index += 1 }
                } else {
                    endSegment(nextAfterPipe: false)
                }
            case ">":
                endWord()
                if next() == "(" { return fail(substitution) }
                if next() == ">" || next() == "|" { index += 1 }
                if next() == "&" { index += 1 }
            case "<":
                endWord()
                if next() == "(" { return fail(substitution) }
                if next() == "<" { return fail("Uses a here-document the check cannot read") }
                if next() == "&" || next() == ">" { index += 1 }
            case "'":
                raw.append(scalar)
                inWord = true
                index += 1
                while index < scalars.count, scalars[index] != "'" {
                    word.append(scalars[index])
                    raw.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count else { return fail("Has a quote that is not closed") }
                raw.append(scalars[index])
            case "\"":
                raw.append(scalar)
                inWord = true
                index += 1
                while index < scalars.count, scalars[index] != "\"" {
                    let inner = scalars[index]
                    if inner == "`" { return fail(substitution) }
                    if inner == "\\" { return fail("Uses a backslash escape the check cannot read") }
                    if inner == "$" {
                        guard let length = plainVariable(at: index) else { return fail(dollarProblem(at: index)) }
                        appendVariable(length)
                        continue
                    }
                    word.append(inner)
                    raw.append(inner)
                    index += 1
                }
                guard index < scalars.count else { return fail("Has a quote that is not closed") }
                raw.append(scalars[index])
            case "$":
                guard let length = plainVariable(at: index) else { return fail(dollarProblem(at: index)) }
                appendVariable(length)
                continue
            case "`":
                return fail(substitution)
            case "\\":
                return fail("Uses a backslash escape the check cannot read")
            case "*", "?", "[", "]":
                return fail("Uses wildcards the check cannot read")
            case "{", "}":
                return fail(expansion)
            default:
                guard isPlain(scalar) else { return fail("Uses characters the check cannot read") }
                word.append(scalar)
                raw.append(scalar)
                inWord = true
            }
            index += 1
        }
        endSegment(nextAfterPipe: false)
        return ShellReading(segments: segments, problem: nil)
    }
}
