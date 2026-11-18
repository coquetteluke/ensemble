import Foundation

/// Why a dev server command from `.ensemble/launch.json` was refused.
public enum LaunchCommandError: Error, LocalizedError, Equatable, Sendable {
    case empty
    case tooLong
    case unclosedQuote
    case trailingBackslash
    /// A character a shell would treat specially (`;`, `|`, `&`, `$`, a glob, a redirect). The command runs without a
    /// shell, so it is refused instead of being passed on as plain text.
    case shellSyntax(String)
    /// `NAME=value` before the program: an environment assignment needs a shell.
    case variableAssignment(String)
    case controlCharacter

    public var errorDescription: String? {
        switch self {
        case .empty: "The command is empty."
        case .tooLong: "The command is longer than \(LaunchCommand.maxLength) characters or \(LaunchCommand.maxArguments) arguments."
        case .unclosedQuote: "The command has a quote that is never closed."
        case .trailingBackslash: "The command ends with a backslash."
        case .shellSyntax(let text): "The command uses \(text), which needs a shell. Ensemble runs the program directly, without a shell."
        case .variableAssignment(let word): "The command starts with \(word). Setting variables needs a shell, and Ensemble runs the program directly."
        case .controlCharacter: "The command has a line break or another control character."
        }
    }
}

/// Turns a dev server command into the program and its arguments, the way a shell splits words, but with no shell:
/// no variables, globs, pipes, redirects, command lists or substitutions. Anything that would mean something to a
/// shell outside quotes is refused, so what runs is exactly the words the user confirmed.
///
/// - Spaces and tabs separate words. `'single quotes'` keep everything as written. `"double quotes"` keep everything
///   except `\"` and `\\`; `$` and backticks inside them are refused, because a shell would expand them.
/// - A backslash outside quotes keeps the next character as written.
public enum LaunchCommand {
    public static let maxLength = 2000
    public static let maxArguments = 100

    /// Characters refused outside quotes.
    static let shellCharacters: Set<Character> = [";", "|", "&", "<", ">", "(", ")", "`", "$", "*", "?", "[", "]", "{", "}"]
    /// Refused at the start of a word outside quotes (home folder expansion and comments).
    static let wordStartCharacters: Set<Character> = ["~", "#"]

    public static func split(_ command: String) throws(LaunchCommandError) -> [String] {
        guard command.count <= maxLength else { throw .tooLong }
        var words: [String] = []
        var current = ""
        /// True once the current word has started (so `''` makes an empty argument).
        var inWord = false
        var characters = command.makeIterator()

        func describe(_ character: Character) -> String {
            switch character {
            case "$": "$ (variables and substitutions)"
            case "`": "backticks (substitutions)"
            case ";": "; (command lists)"
            case "|": "| (pipes)"
            case "&": "& (background jobs and command lists)"
            case "<", ">": "\(character) (redirects)"
            case "(", ")": "\(character) (subshells)"
            case "*", "?", "[", "]": "\(character) (file name patterns)"
            case "{", "}": "\(character) (brace expansion)"
            case "~": "~ (home folder expansion)"
            case "#": "# (comments)"
            default: String(character)
            }
        }

        while let character = characters.next() {
            if character == " " || character == "\t" {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            if isControl(character) { throw .controlCharacter }
            switch character {
            case "'":
                inWord = true
                var closed = false
                while let next = characters.next() {
                    if next == "'" { closed = true; break }
                    if isControl(next) { throw .controlCharacter }
                    current.append(next)
                }
                if !closed { throw .unclosedQuote }
            case "\"":
                inWord = true
                var closed = false
                while let next = characters.next() {
                    if next == "\"" { closed = true; break }
                    if isControl(next) { throw .controlCharacter }
                    if next == "$" || next == "`" { throw .shellSyntax(describe(next)) }
                    if next == "\\" {
                        guard let escaped = characters.next() else { throw .unclosedQuote }
                        if isControl(escaped) { throw .controlCharacter }
                        // Like a shell: only \" \\ \$ and \` lose the backslash inside double quotes.
                        if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" {
                            current.append(escaped)
                        } else {
                            current.append("\\")
                            current.append(escaped)
                        }
                        continue
                    }
                    current.append(next)
                }
                if !closed { throw .unclosedQuote }
            case "\\":
                guard let escaped = characters.next() else { throw .trailingBackslash }
                if isControl(escaped) { throw .controlCharacter }
                inWord = true
                current.append(escaped)
            default:
                if shellCharacters.contains(character) { throw .shellSyntax(describe(character)) }
                if !inWord, wordStartCharacters.contains(character) { throw .shellSyntax(describe(character)) }
                inWord = true
                current.append(character)
            }
        }
        if inWord { words.append(current) }
        guard let first = words.first else { throw .empty }
        guard words.count <= maxArguments else { throw .tooLong }
        if isAssignment(first) { throw .variableAssignment(first) }
        return words
    }

    /// Checks a command given as a list of words (`"command": ["npm", "run", "dev"]`): nothing is split or expanded,
    /// but control characters, an empty program and a leading `NAME=value` are refused.
    public static func validate(_ words: [String]) throws(LaunchCommandError) -> [String] {
        guard let first = words.first, !first.isEmpty else { throw .empty }
        guard words.count <= maxArguments, words.reduce(0, { $0 + $1.count + 1 }) <= maxLength else { throw .tooLong }
        for word in words where word.contains(where: isControl) { throw .controlCharacter }
        if isAssignment(first) { throw .variableAssignment(first) }
        return words
    }

    /// The words as one line a person can read and that `split` turns back into the same words: each word that holds
    /// anything but letters, digits and `@%+=:,./-_` is put in single quotes.
    public static func display(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) }),
           !(word.first.map { wordStartCharacters.contains($0) } ?? false) {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) } && name.allSatisfy(\.isASCII)
    }

    // MARK: Running

    /// Folders searched for a program named without a slash, after the app's own PATH. Apps opened from the Finder
    /// get a short PATH, so the usual install places are added.
    public static func searchPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.deno/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
                      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            where !path.contains(extra) {
            path.append(extra)
        }
        return path
    }

    /// The program to run: a name with a slash is a path (relative to the folder unless it starts with `/`); a bare
    /// name is looked up in `searchPath`. Nil when there is no executable file there.
    public static func resolveExecutable(_ program: String, folder: String, searchPath: [String]) -> URL? {
        let fm = FileManager.default
        func executable(_ path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if program.contains("/") {
            let path = program.hasPrefix("/") ? program : (folder as NSString).appendingPathComponent(program)
            return executable(path)
        }
        for directory in searchPath where directory.hasPrefix("/") {
            if let url = executable((directory as NSString).appendingPathComponent(program)) { return url }
        }
        return nil
    }

    /// The dev server's environment: Ensemble's own, without agent sign-ins and session markers, with `searchPath` as
    /// PATH and `BROWSER=none` (so servers do not open the default browser; the pane loads the page instead).
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in base {
            let upper = key.uppercased()
            if upper.hasPrefix("ANTHROPIC_") || upper.hasPrefix("CLAUDE") || upper.hasPrefix("OPENCODE") || upper.hasPrefix("GEMINI_")
                || upper.hasPrefix("ENSEMBLE_") {
                continue
            }
            env[key] = value
        }
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = searchPath(environment: base).joined(separator: ":")
        env["BROWSER"] = "none"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }
}
