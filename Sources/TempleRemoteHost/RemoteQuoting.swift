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

    /// `env PATH=<path> sh -c <script> temple <args…>`, or without the
    /// assignment when no PATH was resolved (ssh's default environment).
    /// Every remote command Temple runs has this shape (one environment
    /// policy, docs/designs/remote-ssh.md section 2).
    public static func shellCommand(script: String, args: [String], path: String?) -> String {
        var words: [String] = []
        if let path { words += ["env", "PATH=\(path)"] }
        words += ["sh", "-c", script, "temple"] + args
        // `env` and `sh` are plain words; quoting them too keeps one rule.
        return command(words)
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
