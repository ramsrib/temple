import Foundation

/// Splits a command-line string into argv the way a shell would.
///
/// The naive `split(separator: " ")` this replaces silently mangled any argument
/// carrying a value with a space in it — `--append-system-prompt "be terse"` became
/// three arguments, two of them with stray quote marks, and the agent received
/// nonsense. A user typing a perfectly ordinary flag had no way to see why.
///
/// This is the inverse of `ShellQuoting.commandLine`, which puts argv *back* into a
/// string for libghostty.
public enum ShellWords {

    /// Inside double quotes a backslash escapes only these; before anything else it
    /// is an ordinary character, exactly as in a POSIX shell. Getting this wrong is
    /// not a rounding error: `--prompt "match \d+"` would silently reach the agent as
    /// `match d+`, a different argument than the one the user typed.
    private static let escapableInDoubleQuotes: Set<Character> = ["$", "`", "\"", "\\", "\n"]

    /// Tokenize `line` into arguments: whitespace separates, single quotes are
    /// literal, double quotes allow a restricted set of backslash escapes, and a
    /// backslash outside quotes escapes the next character.
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false          // distinguishes `""` (an empty argument) from no argument
        var quote: Character?        // the quote we're inside, if any
        var escaped = false

        for character in line {
            if escaped {
                // In double quotes the backslash only escapes a few characters; before
                // any other it stands for itself and must survive.
                if quote == "\"" && !escapableInDoubleQuotes.contains(character) {
                    current.append("\\")
                }
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where quote != "'":
                // A backslash is literal inside single quotes, an escape anywhere else.
                escaped = true
                hasWord = true
            case "'", "\"":
                if let open = quote {
                    if open == character { quote = nil } else { current.append(character) }
                } else {
                    quote = character
                    hasWord = true
                }
            case " ", "\t", "\n":
                if quote != nil {
                    current.append(character)
                } else if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
            default:
                current.append(character)
                hasWord = true
            }
        }
        // A trailing backslash is a line continuation to a shell, but this is a
        // one-line settings field: the user typed a character, so keep it rather than
        // silently deleting it.
        if escaped {
            current.append("\\")
            hasWord = true
        }
        if hasWord { words.append(current) }
        return words
    }
}
