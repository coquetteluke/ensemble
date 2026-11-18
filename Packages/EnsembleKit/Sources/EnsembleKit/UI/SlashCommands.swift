import Foundation

/// An entry in the composer's `/` menu: one of Ensemble's own commands, or the engine's.
public struct SlashCommand: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case ensemble, engineCommand, engineSkill }

    /// Without the leading slash.
    public var name: String
    public var summary: String
    public var argumentHint: String?
    public var source: Source
    public var symbol: String

    public var id: String { "\(source.rawValue):\(name)" }

    public init(name: String, summary: String, argumentHint: String? = nil, source: Source, symbol: String) {
        self.name = name
        self.summary = summary
        self.argumentHint = argumentHint
        self.source = source
        self.symbol = symbol
    }
}

public enum SlashCommands {
    /// Ensemble's own commands, handled by the app.
    public static let builtIn: [SlashCommand] = [
        SlashCommand(name: "new", summary: "Start a new session", source: .ensemble, symbol: "square.and.pencil"),
        SlashCommand(name: "model", summary: "Switch the model", argumentHint: "<model>", source: .ensemble, symbol: "cpu"),
        SlashCommand(name: "effort", summary: "Set how hard the model thinks", argumentHint: "<low|medium|high|xhigh|max>", source: .ensemble, symbol: "gauge.with.dots.needle.50percent"),
        SlashCommand(name: "fast", summary: "Turn fast mode on or off", source: .ensemble, symbol: "bolt"),
        SlashCommand(name: "mode", summary: "Change the permission mode", argumentHint: "<ask|edits|auto|bypass>", source: .ensemble, symbol: "hand.raised"),
        SlashCommand(name: "compact", summary: "Summarise the conversation to free up context", source: .ensemble, symbol: "arrow.down.right.and.arrow.up.left"),
        SlashCommand(name: "fork", summary: "Copy this session into a new one", source: .ensemble, symbol: "arrow.triangle.branch"),
        SlashCommand(name: "rewind", summary: "Go back to before your last message", source: .ensemble, symbol: "arrow.counterclockwise"),
        SlashCommand(name: "clear", summary: "Start fresh in the same folder and model", source: .ensemble, symbol: "eraser"),
        SlashCommand(name: "hub", summary: "Open the Session Hub", source: .ensemble, symbol: "square.grid.2x2"),
        SlashCommand(name: "usage", summary: "Show cost and tokens for this session", source: .ensemble, symbol: "chart.bar"),
        SlashCommand(name: "help", summary: "List keyboard shortcuts and commands", source: .ensemble, symbol: "questionmark.circle"),
    ]

    /// Ensemble's commands first, then the engine's commands and skills. An engine command with the
    /// same name as one of Ensemble's is left out (Ensemble's handles it, using the engine's when needed).
    public static func catalog(engine: [EngineCommand]) -> [SlashCommand] {
        let builtInNames = Set(builtIn.map(\.name))
        let extra = engine
            .filter { !builtInNames.contains($0.name) }
            .map { command in
                SlashCommand(name: command.name, summary: command.summary, argumentHint: command.argumentHint,
                             source: command.kind == .skill ? .engineSkill : .engineCommand,
                             symbol: command.kind == .skill ? "sparkles" : "terminal")
            }
            .sorted { ($0.source == .engineCommand ? 0 : 1, $0.name) < ($1.source == .engineCommand ? 0 : 1, $1.name) }
        return builtIn + extra
    }

    /// The command name being typed when the draft is a bare `/name` (no spaces or new lines yet).
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        return String(rest)
    }

    /// Commands matching `query`, kept in their sections (Ensemble, commands, skills) so each heading shows
    /// once; within a section, names starting with the query come first, then names or summaries containing it.
    public static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = commands.filter {
            !$0.name.lowercased().hasPrefix(q) && ($0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q))
        }
        let ranked = prefix + contains
        let sections: [SlashCommand.Source] = [.ensemble, .engineCommand, .engineSkill]
        return sections.flatMap { section in ranked.filter { $0.source == section } }
    }

    /// Splits "/name some arguments" into its parts. Nil when the text is not a command.
    public static func parse(_ text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        guard let first = body.first, first.isLetter || first.isNumber else { return nil }
        if let space = body.firstIndex(where: { $0 == " " || $0 == "\n" }) {
            return (String(body[..<space]), body[space...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (String(body), "")
    }
}
