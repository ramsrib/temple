import Foundation
import TempleCore

/// One parsed `temple` command (ADR-034): a noun, a verb, and the few flags
/// the verbs share. Parsing never touches the app or the disk.
public struct Invocation: Equatable, Sendable {
    public enum Noun: String, CaseIterable, Sendable { case projects, sessions, history }
    public enum Verb: String, Sendable { case ls, get, search, new, open, close }

    public var noun: Noun
    public var verb: Verb
    /// The verb's one argument: an id, a folder or a search term.
    public var argument: String?
    public var project: String?
    public var cli: Agent?
    public var force = false
    public var json = false

    public init(noun: Noun, verb: Verb, argument: String? = nil, project: String? = nil, cli: Agent? = nil,
                force: Bool = false, json: Bool = false) {
        self.noun = noun; self.verb = verb; self.argument = argument; self.project = project
        self.cli = cli; self.force = force; self.json = json
    }

    /// What each noun answers to, and what its verb's argument is.
    static let verbs: [Noun: [(Verb, Argument)]] = [
        .projects: [(.ls, .none), (.get, .required("dir"))],
        .sessions: [(.ls, .none), (.search, .required("term")), (.get, .required("id")),
                    (.new, .optional("dir")), (.open, .required("id")), (.close, .required("id"))],
        .history: [(.ls, .none), (.search, .required("term")), (.get, .required("id"))],
    ]

    enum Argument: Equatable {
        case none
        case required(String)
        case optional(String)
    }

    /// Which flags a verb takes; anything else is a usage error rather than
    /// silently ignored.
    static func flags(_ noun: Noun, _ verb: Verb) -> Set<String> {
        var flags: Set<String> = ["--json"]
        switch (noun, verb) {
        case (.sessions, .ls), (.history, .ls): flags.formUnion(["--project", "--cli"])
        case (.sessions, .search), (.history, .search), (.sessions, .new): flags.insert("--cli")
        case (.sessions, .close): flags.insert("--force")
        default: break
        }
        return flags
    }
}

public enum ParseResult: Equatable, Sendable {
    case run(Invocation)
    /// Help text for the whole command, or for one noun.
    case help(Invocation.Noun?)
    case usageError(String, Invocation.Noun?)
}

public enum ArgumentParser {
    public static func parse(_ arguments: [String]) -> ParseResult {
        var words: [String] = []
        var project: String?
        var cli: Agent?
        var force = false
        var json = false
        var seenFlags: [String] = []
        var wantsHelp = false
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            switch word {
            case "-h", "--help":
                wantsHelp = true
            case "--json":
                json = true; seenFlags.append(word)
            case "--force":
                force = true; seenFlags.append(word)
            case "--project", "--cli":
                guard index < arguments.count else { return .usageError("\(word) needs a value", noun(words)) }
                let value = arguments[index]
                index += 1
                seenFlags.append(word)
                if word == "--project" { project = value }
                else {
                    guard let agent = Agent(rawValue: value.lowercased()) else {
                        let names = Agent.allCases.map(\.rawValue).joined(separator: ", ")
                        return .usageError("unknown CLI \"\(value)\" (one of: \(names))", noun(words))
                    }
                    cli = agent
                }
            case "--":
                words.append(contentsOf: arguments[index...])
                index = arguments.count
            default:
                if word.hasPrefix("-"), word.count > 1 { return .usageError("unknown flag \(word)", noun(words)) }
                words.append(word)
            }
        }
        guard let first = words.first else { return wantsHelp ? .help(nil) : .usageError("missing a command", nil) }
        guard let noun = Invocation.Noun(rawValue: first) else {
            return .usageError("unknown command \"\(first)\"", nil)
        }
        if wantsHelp { return .help(noun) }
        guard words.count > 1 else { return .usageError("\(noun.rawValue) needs a verb", noun) }
        let verbs = Invocation.verbs[noun] ?? []
        guard let verb = Invocation.Verb(rawValue: words[1]),
              let (_, argument) = verbs.first(where: { $0.0 == verb }) else {
            return .usageError("\(noun.rawValue) has no verb \"\(words[1])\"", noun)
        }
        let rest = Array(words.dropFirst(2))
        switch argument {
        case .none:
            guard rest.isEmpty else { return .usageError("\(noun.rawValue) \(verb.rawValue) takes no argument", noun) }
        case .required(let name):
            guard rest.count == 1 else {
                return .usageError("\(noun.rawValue) \(verb.rawValue) needs exactly one <\(name)>", noun)
            }
        case .optional(let name):
            guard rest.count <= 1 else {
                return .usageError("\(noun.rawValue) \(verb.rawValue) takes at most one <\(name)>", noun)
            }
        }
        let allowed = Invocation.flags(noun, verb)
        if let stray = seenFlags.first(where: { !allowed.contains($0) }) {
            return .usageError("\(noun.rawValue) \(verb.rawValue) does not take \(stray)", noun)
        }
        return .run(Invocation(noun: noun, verb: verb, argument: rest.first, project: project, cli: cli,
                               force: force, json: json))
    }

    private static func noun(_ words: [String]) -> Invocation.Noun? {
        words.first.flatMap(Invocation.Noun.init(rawValue:))
    }

    public static func helpText(_ noun: Invocation.Noun?) -> String {
        switch noun {
        case nil:
            return """
            Usage: temple <command> <verb> [arguments] [--json]

            Your open projects and sessions, and History for everything else.

            Commands:
              projects   Projects with an open tab
              sessions   Sessions with an open tab; start, open and close them
              history    Every session: open, closed, archived, never imported

            Run `temple <command> --help` for its verbs.
            """
        case .projects:
            return """
            Usage: temple projects <verb>

              ls                 Projects with an open tab (* marks the one on screen)
              get <dir>          One project and its open sessions

            Flags: --json
            """
        case .sessions:
            return """
            Usage: temple sessions <verb>

              ls                 Sessions with an open tab (* marks the one on screen)
              search <term>      Open sessions matching a term, best first
              get <id>           One open session, with its resume command
              new [dir]          Start a session in a folder (default: here)
              open <id>          Resume a session in a tab, or focus its tab
              close <id>         Close a session's tab

            Flags:
              --project <dir>    ls: only this project
              --cli <name>       ls, search: only this CLI; new: start this CLI
                                 (claude or codex; default: Temple's setting)
              --force            close: even while its agent is working
              --json             Machine-readable output
            """
        case .history:
            return """
            Usage: temple history <verb>

              ls                 Every session, newest first
              search <term>      Sessions matching a term (title, folder, message, id prefix)
              get <id>           One session, with its resume command

            Flags:
              --project <dir>    ls: only this project
              --cli <name>       ls, search: only this CLI (claude or codex)
              --json             Machine-readable output

            `temple sessions open <id>` opens any session History lists.
            """
        }
    }
}
