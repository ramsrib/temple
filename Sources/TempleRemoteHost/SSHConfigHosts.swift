import Foundation

/// One alias an ssh config names, with what its own `Host` blocks set
/// (keyword lowercased to its first value, as ssh takes it). Only a block
/// whose `Host` line names the alias itself counts: a pattern's block
/// (`Host *` included) and a `Match` block are not the alias's own. For
/// ordering and labelling what Add host offers, never for connecting: ssh
/// resolves the host itself when it is used.
public struct SSHConfigHost: Equatable, Sendable, ExpressibleByStringLiteral {
    public let alias: String
    /// Keyword (lowercased) to its first value, from the alias's own blocks.
    public let options: [String: String]

    public init(alias: String, options: [String: String] = [:]) {
        self.alias = alias; self.options = options
    }

    public init(stringLiteral alias: String) { self.init(alias: alias) }

    /// It names how to log in: a `User` or an `IdentityFile`.
    public var setsLogin: Bool { options["user"] != nil || options["identityfile"] != nil }

    /// The alias's own `HostName`, `%h` and `%%` expanded as ssh does
    /// there; nil when unset or carrying another token.
    public var hostName: String? {
        guard let value = options["hostname"] else { return nil }
        var result = ""
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "%" else { result.unicodeScalars.append(scalar); continue }
            switch scalars.next() {
            case "h": result += alias
            case "%": result += "%"
            default: return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    /// A bare name: no login set, and it goes where it says (`Host
    /// github.com` with no `HostName`, or one equal to the alias). Other
    /// options (a `ProxyJump`, a `Port`) don't count either way.
    public var isBare: Bool {
        !setsLogin && (hostName ?? alias).lowercased() == alias.lowercased()
    }

    /// `user@hostname` from the alias's own `User` and `HostName`, as far
    /// as they are set (the hostname is the alias when only `User` is);
    /// nil when neither is, or the user carries a `%` token.
    public var destination: String? {
        let user = options["user"].flatMap { $0.isEmpty || $0.contains("%") ? nil : $0 }
        switch (user, hostName) {
        case let (user?, host?): return "\(user)@\(host)"
        case let (nil, host?): return host
        case let (user?, nil): return "\(user)@\(alias)"
        case (nil, nil): return nil
        }
    }
}

/// The host aliases in an ssh config, read-only: every name on a `Host`
/// line, in file order, following `Include` one level deep. Patterns
/// (`*`, `?`), negations (`!name`) and `Match` blocks are skipped: they
/// match hosts rather than name one, so there is nothing to pick.
///
/// Temple never writes an ssh config, and never runs anything a config
/// says (a `Match exec` included). It lists aliases so the user can turn
/// one on; ssh resolves everything else about it when it connects.
public enum SSHConfigHosts {
    /// One line that matters here, in file order.
    enum Statement: Equatable {
        /// A `Host` line's patterns as written (nil words: none).
        case host([String])
        case match
        case include([String])
        /// Any other keyword (lowercased) and its first value.
        case option(String, String)
    }

    static func statements(in text: String) -> [Statement] {
        var statements: [Statement] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.unicodeScalars.first, first != "#" else { continue }
            guard let (keyword, rest) = splitKeyword(line) else { continue }
            switch keyword.lowercased() {
            case "host":
                statements.append(.host(words(rest) ?? []))
            case "match":
                statements.append(.match)
            case "include":
                let paths = words(rest) ?? []
                if !paths.isEmpty { statements.append(.include(paths)) }
            default:
                if let value = words(rest)?.first { statements.append(.option(keyword.lowercased(), value)) }
            }
        }
        return statements
    }

    /// The aliases a statement list names directly, in order.
    private static func names(_ statements: [Statement]) -> [String] {
        statements.flatMap { statement -> [String] in
            if case .host(let patterns) = statement { return patterns.filter(isAlias) }
            return []
        }
    }

    /// Aliases in `text` alone (no includes followed).
    public static func aliases(in text: String) -> [String] {
        unique(names(statements(in: text)))
    }

    /// Aliases in the config at `configURL`, with the files it includes read
    /// once (one level: an `Include` inside an included file is not
    /// followed). Relative include paths are taken from `sshDirectory`, as
    /// ssh does for a user config; globs are expanded. A file that cannot be
    /// read contributes nothing.
    public static func load(configURL: URL, sshDirectory: URL,
                            home: String = NSHomeDirectory(),
                            read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> [String] {
        loadHosts(configURL: configURL, sshDirectory: sshDirectory, home: home, read: read).map(\.alias)
    }

    /// `load`'s aliases, each with what its own blocks set, read as ssh
    /// reads the file for that name (`walk`).
    public static func loadHosts(configURL: URL, sshDirectory: URL,
                                 home: String = NSHomeDirectory(),
                                 read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> [SSHConfigHost] {
        guard let text = read(configURL) else { return [] }
        let top = statements(in: text)
        // Each included file read once, in the order ssh reads them.
        var included: [String: [[Statement]]] = [:]
        var found: [String] = []
        for statement in top {
            switch statement {
            case .host(let patterns):
                found += patterns.filter(isAlias)
            case .include(let patterns):
                let key = patterns.joined(separator: "\u{0}")
                let files = patterns.flatMap { expand($0, sshDirectory: sshDirectory, home: home) }
                    .compactMap { read(URL(fileURLWithPath: $0)).map(statements(in:)) }
                included[key] = files
                found += files.flatMap(names)
            case .match, .option:
                continue
            }
        }
        return unique(found).map { alias in
            var options: [String: String] = [:]
            var state = WalkState(active: true, own: false)
            walk(top, alias: alias, state: &state, neverMatch: false, included: included, into: &options)
            return SSHConfigHost(alias: alias, options: options)
        }
    }

    /// Where ssh is in a file for one name: whether the lines apply to it
    /// (`active`, as ssh's) and whether they are the alias's own (a `Host`
    /// line naming it, not only a pattern matching it). The top of the file,
    /// before any `Host`, applies to every name and is no one's own.
    struct WalkState: Equatable {
        var active: Bool
        var own: Bool
    }

    /// The statements in order as ssh reads them for `alias` (readconf.c):
    /// a `Host` line sets whether what follows applies; an `Include` reads
    /// each file with the state it appears in, which is restored after each
    /// file, and a file included where nothing applies can match nothing
    /// (`SSHCONF_NEVERMATCH`); the first value of a keyword wins. A `Match`
    /// is never evaluated (its `exec` would run a command): what follows
    /// it is taken as not applying.
    private static func walk(_ statements: [Statement], alias: String, state: inout WalkState, neverMatch: Bool,
                             included: [String: [[Statement]]]?, into options: inout [String: String]) {
        for statement in statements {
            switch statement {
            case .host(let patterns):
                let matches = !neverMatch && hostMatches(alias, patterns)
                state = WalkState(active: matches,
                                  own: matches && patterns.contains { isAlias($0) && $0.lowercased() == alias.lowercased() })
            case .match:
                state = WalkState(active: false, own: false)
            case .include(let patterns):
                // One level: an included file's own Include is not followed.
                guard let files = included?[patterns.joined(separator: "\u{0}")] else { continue }
                let saved = state
                for file in files {
                    walk(file, alias: alias, state: &state, neverMatch: neverMatch || !saved.active,
                         included: nil, into: &options)
                    state = saved
                }
            case .option(let keyword, let value):
                if state.own, options[keyword] == nil { options[keyword] = value }
            }
        }
    }

    /// ssh's `Host` matching (match_hostname_list): no negated pattern may
    /// match, and some plain one must; `*` and `?` wildcards; ignoring case.
    static func hostMatches(_ name: String, _ patterns: [String]) -> Bool {
        let name = Array(name.lowercased().unicodeScalars)
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcard(name, Array(pattern.dropFirst().lowercased().unicodeScalars)) { return false }
            } else if wildcard(name, Array(pattern.lowercased().unicodeScalars)) {
                matched = true
            }
        }
        return matched
    }

    private static func wildcard(_ name: [Unicode.Scalar], _ pattern: [Unicode.Scalar]) -> Bool {
        var n = 0, p = 0, star = -1, mark = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
                n += 1; p += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = n; p += 1
            } else if star >= 0 {
                p = star + 1; mark += 1; n = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
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
        let scalars = word.unicodeScalars
        guard let first = scalars.first, first != "!", first != "-" else { return false }
        return !scalars.contains("*") && !scalars.contains("?")
    }

    /// `Keyword value…` or `Keyword=value…`, as ssh accepts both (by
    /// scalar, like the rest of the reader).
    private static func splitKeyword(_ line: String) -> (String, String)? {
        let scalars = line.unicodeScalars
        guard let end = scalars.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line, "")
        }
        let keyword = String(scalars[..<end])
        var rest = scalars[end...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (keyword, String(String.UnicodeScalarView(rest)))
    }

    /// A line's arguments as OpenSSH's `argv_split` reads them (misc.c):
    /// separated by spaces or tabs; single or double quotes group, and do not
    /// nest; a backslash escapes a quote of either kind, a backslash, or
    /// (outside quotes) a space, and is kept before anything else; `#` at
    /// the start of a word ends the line. A quote left open makes the line
    /// invalid, as ssh says ("invalid quotes"): nil.
    static func words(_ text: String) -> [String]? {
        // Scalars, as ssh reads bytes: a quote or backslash with a combining
        // mark after it still quotes or escapes.
        let s = Array(text.unicodeScalars)
        var words: [String] = []
        var i = 0
        while i < s.count {
            if s[i] == " " || s[i] == "\t" { i += 1; continue }
            if s[i] == "#" { break }
            var word = String.UnicodeScalarView()
            var quote: Unicode.Scalar?
            while i < s.count {
                let c = s[i]
                if c == "\\" {
                    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
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
            words.append(String(word))
        }
        return words
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
