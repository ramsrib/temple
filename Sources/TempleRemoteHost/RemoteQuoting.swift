import Foundation

/// The one quoting function for everything Temple hands a remote shell.
///
/// ssh passes a remote command to the login shell of the account it logs in
/// to, which may be sh, bash, zsh or fish. Each argument becomes one single-
/// quoted word. A single quote inside it is written `'\''` (close, an escaped
/// quote, reopen) and a backslash `'\\'` (close, an escaped backslash,
/// reopen): fish treats `\'` and `\\` as escapes even inside single quotes,
/// so neither character ever appears inside the quotes, and the four shells
/// read the word the same way. Newlines need nothing.
///
/// Script text is fixed and travels as one quoted argument to `sh -c`; what
/// varies travels as further quoted, positional arguments, never spliced
/// into a script.
public enum RemoteQuoting {
    /// Works on Unicode scalars, never Characters: a quote followed by a
    /// combining mark is one Character, which a Character comparison would
    /// miss, while every shell reads the quote byte on its own.
    public static func quote(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        out.append("'")
        for scalar in word.unicodeScalars {
            switch scalar {
            case "'": out.append(contentsOf: #"'\''"#.unicodeScalars)
            case "\\": out.append(contentsOf: #"'\\'"#.unicodeScalars)
            default: out.append(scalar)
            }
        }
        out.append("'")
        return String(out)
    }

    /// Several words, each quoted, separated by spaces.
    public static func command(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// The fixed bootstrap every query runs, arguments: its end line, then
    /// an optional marker. It prints the marker on stdout and stderr first
    /// (here, in `sh`: a login shell's own syntax never touches it; csh's
    /// `>&2` is not a redirection to stderr), then reads the program from
    /// stdin a line at a time (`read` takes no more than the line from a
    /// pipe), up to the end line, and runs it only if the end line
    /// arrived: a program cut short in transit runs nothing. What follows
    /// the end line stays on stdin, for the program.
    static let bootstrap = #"[ -z "$2" ] || { printf '%s\n' "$2"; printf '%s\n' "$2" >&2; }; "#
        + #"NL=$(printf '\nx'); NL=${NL%x}; p=; g=; "#
        + #"while IFS= read -r l; do if [ "$l" = "$1" ]; then g=1; break; fi; p=$p$l$NL; done; "#
        + #"[ -n "$g" ] || exit 97; eval "$p""#

    /// How every query travels (one environment policy, docs/designs/
    /// remote-ssh.md section 2): on the command line only the fixed
    /// bootstrap, its end line and the marker, the same few hundred bytes
    /// for every query; on stdin the program (the arguments as `set --`,
    /// the resolved PATH when there is one, then the fixed script), the end
    /// line, then the query's own input. Nothing variable is ever in a
    /// command line, so no value can grow one (design note 21). The end
    /// line is one that appears nowhere in the encoded program (`end` is
    /// tried first, then fresh ones), so no argument, PATH or script line
    /// can end the program early; in the query's own input it is harmless.
    public static func invocation(script: String, args: [String], path: String?, input: Data?, marker: String? = nil,
                                  end: String? = nil) -> (command: String, stdin: Data) {
        var program = "set --"
        for arg in args { program += " " + quote(arg) }
        program += "\n"
        if let path { program += "PATH=\(quote(path)); export PATH\n" }
        program += script + "\n"
        // Lines as `read` splits them: on the byte 0x0A, not on Characters
        // (a CRLF is one Character, but its LF still ends a line for sh).
        let lines = Set(Array(program.utf8).split(separator: 0x0A, omittingEmptySubsequences: false).map { Array($0) })
        var chosen = end ?? "__temple_end_\(nonce())__"
        while lines.contains(Array(chosen.utf8)) { chosen = "__temple_end_\(nonce())__" }
        var stdin = Data((program + chosen + "\n").utf8)
        if let input { stdin.append(input) }
        return (command(["sh", "-c", bootstrap, "temple", chosen] + (marker.map { [$0] } ?? [])), stdin)
    }

    /// Ids, handles and nonces: what may name something on a host.
    public static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
                || byte == 0x2e || byte == 0x5f || byte == 0x2d
        }
    }

    /// A random token for markers and throwaway names.
    public static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
