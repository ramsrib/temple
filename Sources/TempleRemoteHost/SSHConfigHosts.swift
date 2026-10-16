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
                let names = (words(rest) ?? []).filter(isAlias)
                if !names.isEmpty { entries.append(.host(names)) }
            case "include":
                let paths = words(rest) ?? []
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

    /// A line's arguments as OpenSSH's `argv_split` reads them (misc.c):
    /// separated by spaces or tabs; single or double quotes group, and do not
    /// nest; a backslash escapes a quote of either kind, a backslash, or
    /// (outside quotes) a space, and is kept before anything else; `#` at
    /// the start of a word ends the line. A quote left open makes the line
    /// invalid, as ssh says ("invalid quotes"): nil.
    static func words(_ text: String) -> [String]? {
        let s = Array(text)
        var words: [String] = []
        var i = 0
        while i < s.count {
            if s[i] == " " || s[i] == "\t" { i += 1; continue }
            if s[i] == "#" { break }
            var word = ""
            var quote: Character?
            while i < s.count {
                let c = s[i]
                if c == "\\" {
                    let next: Character? = i + 1 < s.count ? s[i + 1] : nil
                    if let next, next == "'" || next == "\"" || next == "\\" || (quote == nil && next == " ") {
                        i += 1
                        word.append(next)
                    } else {
                        word.append(c)
                    }
                } else if quote == nil, c == " " || c == "\t" {
                    break
                } else if quote == nil, c == "\"" || c == "'" {
                    quote = c
                } else if let open = quote, c == open {
                    quote = nil
                } else {
                    word.append(c)
                }
                i += 1
            }
            if quote != nil { return nil }
            words.append(word)
        }
        return words
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
