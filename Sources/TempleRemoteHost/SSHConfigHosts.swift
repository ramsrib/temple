import Foundation

/// The host aliases in an ssh config, read-only: every name on a `Host`
/// line, in file order, following `Include` one level deep. Patterns
/// (`*`, `?`), negations (`!name`) and `Match` blocks are skipped: they
/// match hosts rather than name one, so there is nothing to pick.
///
/// Temple never writes an ssh config. It lists aliases so the user can turn
/// one on; ssh resolves everything else about it when it connects.
public enum SSHConfigHosts {
    enum Entry: Equatable {
        case host([String])
        case include([String])
    }

    /// Every alias `text` names directly, and its `Include` arguments, in order.
    static func entries(in text: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (keyword, rest) = splitKeyword(line) else { continue }
            switch keyword.lowercased() {
            case "host":
                let names = words(rest).filter(isAlias)
                if !names.isEmpty { entries.append(.host(names)) }
            case "include":
                let paths = words(rest)
                if !paths.isEmpty { entries.append(.include(paths)) }
            default:
                continue
            }
        }
        return entries
    }

    /// Aliases in `text` alone (no includes followed).
    public static func aliases(in text: String) -> [String] {
        unique(entries(in: text).flatMap { entry -> [String] in
            if case .host(let names) = entry { return names }
            return []
        })
    }

    /// Aliases in the config at `configURL`, with the files it includes read
    /// once (one level: an `Include` inside an included file is not
    /// followed). Relative include paths are taken from `sshDirectory`, as
    /// ssh does for a user config; globs are expanded. A file that cannot be
    /// read contributes nothing.
    public static func load(configURL: URL, sshDirectory: URL,
                            home: String = NSHomeDirectory(),
                            read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> [String] {
        guard let text = read(configURL) else { return [] }
        var names: [String] = []
        for entry in entries(in: text) {
            switch entry {
            case .host(let aliases):
                names += aliases
            case .include(let patterns):
                for pattern in patterns {
                    for path in expand(pattern, sshDirectory: sshDirectory, home: home) {
                        guard let included = read(URL(fileURLWithPath: path)) else { continue }
                        names += aliases(in: included)
                    }
                }
            }
        }
        return unique(names)
    }

    /// `~` and relative paths as ssh reads them in a user config, then glob.
    static func expand(_ pattern: String, sshDirectory: URL, home: String) -> [String] {
        var path = pattern
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        if !path.hasPrefix("/") { path = sshDirectory.appendingPathComponent(path).path }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// A name a person can pick: no wildcard, no negation, not an option.
    static func isAlias(_ word: String) -> Bool {
        !word.isEmpty && !word.hasPrefix("!") && !word.hasPrefix("-") && !word.contains("*") && !word.contains("?")
    }

    /// `Keyword value…` or `Keyword=value…`, as ssh accepts both.
    private static func splitKeyword(_ line: String) -> (String, String)? {
        guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line, "")
        }
        let keyword = String(line[..<end])
        var rest = line[end...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (keyword, String(rest))
    }

    /// Whitespace-separated words, double quotes grouping, a `#` outside
    /// quotes ending the line.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var hasWord = false
        for character in text {
            if inQuotes {
                if character == "\"" { inQuotes = false } else { current.append(character) }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true; hasWord = true
            case " ", "\t":
                if hasWord { words.append(current); current = ""; hasWord = false }
            case "#":
                if hasWord { words.append(current) }
                return words
            default:
                current.append(character); hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
