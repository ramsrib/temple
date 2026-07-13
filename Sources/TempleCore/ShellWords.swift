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

    /// Tokenize `line` into arguments: whitespace separates, single quotes are
    /// literal, double quotes allow backslash escapes, and a backslash outside
    /// quotes escapes the next character.
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false          // distinguishes `""` (an empty argument) from no argument
        var quote: Character?        // the quote we're inside, if any
        var escaped = false

        for character in line {
            if escaped {
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
        if hasWord { words.append(current) }
        return words
    }
}
