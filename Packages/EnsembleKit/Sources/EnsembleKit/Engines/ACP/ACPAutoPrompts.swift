import Foundation

/// Reads an ACP permission request for Ensemble's Auto (`SafetyCheckAgents.swift`), for tools whose definition sets
/// `ensembleDecidesAuto`. Only the request's own tool call counts (not earlier updates of the call, not its title or
/// summary), and anything Ensemble does not know makes the request ask.
///
/// What Antigravity (agy 1.5.10, `default` mode) sends, checked 2026-11-18:
/// - every shell command asks: `run_command` with `CommandLine`, `WaitMsBeforeAsync` and `toolSummary` (its tool also
///   has `Cwd`, `Blocking`, `SafeToAutoRun`, `toolAction` and `BypassSandbox`, which asks to run outside agy's sandbox);
/// - every file edit asks: `write_file` (`Path`, `Content`) and `edit_file` (`Path`, `Target`, `Replacement`), with
///   the absolute path in `locations` and a diff;
/// - reads and writes outside the project ask; `search_web` runs without asking.
/// The request also has a non-standard `args` copy of `rawInput`; when both are there they must be the same.
enum ACPAutoPrompts {
    /// Argument names (compared as `ACPAlwaysRules.normalized`) of a shell call that change nothing about what runs or
    /// where: timing, and words written for people. `SafeToAutoRun` is the agent's own opinion, so it is ignored.
    static let ignoredCommandKeys: Set<String> = ACPAlwaysRules.descriptiveKeys.union([
        "toolaction", "safetoautorun", "waitmsbeforeasync", "blocking", "timeout", "timeoutms", "timeoutseconds",
        "notificationtimeoutseconds", "background", "runinbackground", "isbackground",
    ])
    /// Names of the command itself (one of them, exactly once).
    static let commandLineKeys: Set<String> = ["command", "commandline", "cmd"]
    /// Arguments of an edit that never change which file is written, besides `ACPAlwaysRules.allowedFileKeys(kind: "edit")`.
    static let extraEditKeys: Set<String> = [
        "overwrite", "emptyfile", "complexity", "codemarkdownlanguage", "allowmultiple", "targetcontent", "replacementcontent",
        "replacementchunks", "chunks",
    ]

    static let unknownArguments = "The request has arguments the check does not know"
    static let unidentified = "Could not identify the exact command"
    static let leavesSandbox = "Asks to run outside the sandbox"

    /// What the request asks. `params` is the whole `session/request_permission` request, `directory` the session's
    /// folder.
    static func subject(params: JSONValue, directory: String) -> AgentPermissionSubject {
        guard let callJSON = params["toolCall"], let call = ACPToolCallUpdate(callJSON) else {
            return AgentPermissionSubject(action: .other(reason: "The request names no tool call"))
        }
        var tool = ACPToolState(id: call.id)
        tool.merge(call)
        var subject = subject(tool: tool, kind: call.kind, directory: directory)
        subject.toolCallID = call.id
        if let args = callJSON["args"], args != .null, args != tool.rawInput {
            subject.askReason = "The request's arguments do not match"
        }
        return subject
    }

    static func subject(tool: ACPToolState, kind: String?, directory: String) -> AgentPermissionSubject {
        switch kind {
        case "execute": return command(tool, directory: directory)
        case "edit": return edit(tool, directory: directory)
        case "read", "search":
            let outside = tool.permissionKind(directory: directory) == "external_directory"
            return AgentPermissionSubject(action: .other(reason: outside ? SafetyCheckHardRules.outside : "Reading this file always asks"))
        case "delete": return AgentPermissionSubject(action: .other(reason: "Deleting files always asks"))
        case "move": return AgentPermissionSubject(action: .other(reason: "Moving files always asks"))
        case "fetch": return AgentPermissionSubject(action: .other(reason: "Network access always asks"))
        default: return AgentPermissionSubject(action: .other(reason: "Only edits and commands are checked"))
        }
    }

    /// A shell call: the command from its one command field, its folder (inside the project), and nothing else but
    /// `ignoredCommandKeys`. A sandbox argument may only say to stay in the sandbox (`BypassSandbox: false`).
    static func command(_ tool: ACPToolState, directory: String) -> AgentPermissionSubject {
        let project = WorkspaceTrust.resolvedPath(directory) ?? directory
        guard case .object(let input)? = tool.rawInput, let command = ACPFormatting.command(tool.rawInput),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentPermissionSubject(action: .other(reason: unidentified))
        }
        var folder = project
        var commandFields = 0
        var askReason: String?
        for (key, value) in input {
            let word = ACPAlwaysRules.normalized(key)
            if commandLineKeys.contains(word) {
                commandFields += 1
            } else if ACPAlwaysRules.folderKeys.contains(word) {
                guard let text = value.acpText, !text.isEmpty else { askReason = askReason ?? unknownArguments; continue }
                let absolute = text.hasPrefix("/") ? text : (project as NSString).appendingPathComponent(text)
                guard let resolved = WorkspaceTrust.resolvedPath(absolute), ACPFormatting.isInside(resolved, directory: project) else {
                    askReason = askReason ?? SafetyCheckHardRules.outside
                    continue
                }
                folder = resolved
            } else if word.contains("sandbox") {
                if !staysInSandbox(word, value) { askReason = leavesSandbox }
            } else if word == "runpersistent", !isTruthy(value) {
                continue
            } else if !ignoredCommandKeys.contains(word) {
                askReason = askReason ?? unknownArguments
            }
        }
        if commandFields != 1 { askReason = askReason ?? unidentified }
        return AgentPermissionSubject(action: .command(command, folder: folder), askReason: askReason)
    }

    /// A file edit: every path it touches (locations, diffs, path arguments), each inside the project, and only arguments
    /// edits are known to take.
    static func edit(_ tool: ACPToolState, directory: String) -> AgentPermissionSubject {
        let project = WorkspaceTrust.resolvedPath(directory) ?? directory
        guard case .object(let input)? = tool.rawInput, !input.isEmpty else {
            return AgentPermissionSubject(action: .other(reason: "Could not identify the file"))
        }
        guard let paths = tool.touchedPaths(directory: directory), !paths.isEmpty else {
            return AgentPermissionSubject(action: .other(reason: "Could not identify the file"))
        }
        var relative: [String] = []
        for path in paths {
            let prefix = project.hasSuffix("/") ? project : project + "/"
            guard path.hasPrefix(prefix), path.count > prefix.count else {
                return AgentPermissionSubject(action: .other(reason: SafetyCheckHardRules.outside))
            }
            relative.append(String(path.dropFirst(prefix.count)))
        }
        let allowed = ACPAlwaysRules.allowedFileKeys(kind: "edit").union(extraEditKeys)
        let known = onlyKeys(allowed, in: .object(input))
        return AgentPermissionSubject(action: .edit(paths: relative), askReason: known ? nil : unknownArguments)
    }

    /// True when every argument name, at any depth, is in `allowed`.
    static func onlyKeys(_ allowed: Set<String>, in value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            return object.allSatisfy { key, item in allowed.contains(ACPAlwaysRules.normalized(key)) && onlyKeys(allowed, in: item) }
        case .array(let items):
            return items.allSatisfy { onlyKeys(allowed, in: $0) }
        default:
            return true
        }
    }

    /// A sandbox argument that keeps the command in the sandbox: one that asks to leave it (`BypassSandbox`,
    /// `DisableSandbox`, `NoSandbox`, ...) set to false, or one that asks for it (`Sandbox`, `UseSandbox`) set to true.
    static func staysInSandbox(_ word: String, _ value: JSONValue) -> Bool {
        let leaving = ["bypass", "disable", "skip", "escape", "outside", "without", "dangerous", "unsandbox"]
        if leaving.contains(where: word.contains) || word.hasPrefix("no") { return isFalse(value) }
        if ["sandbox", "usesandbox", "sandboxed", "runinsandbox", "insandbox"].contains(word) { return isTruthy(value) }
        return false
    }

    static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .string(let text): return ["true", "yes", "1"].contains(text.lowercased())
        case .number(let number): return number != 0
        default: return false
        }
    }

    static func isFalse(_ value: JSONValue) -> Bool {
        switch value {
        case .bool(let flag): return !flag
        case .string(let text): return ["false", "no", "0"].contains(text.lowercased())
        case .number(let number): return number == 0
        case .null: return true
        default: return false
        }
    }
}

// MARK: Engine

extension ACPEngine: EngineAgentPermissionSupport {
    public func decidesAutoPrompts(for sessionID: String) -> Bool { agent.ensembleDecidesAuto }

    #if os(macOS)
    public func autoPromptSubject(forPermission requestID: String, sessionID: String) async -> AgentPermissionSubject? {
        await core.autoPromptSubject(forPermission: requestID, sessionID: sessionID)
    }
    #else
    public func autoPromptSubject(forPermission requestID: String, sessionID: String) async -> AgentPermissionSubject? { nil }
    #endif
}
