import Foundation

/// POSIX shell quoting, shared by the spawn command line and by drag-and-drop
/// (a dropped path is typed into the agent's prompt, where an unquoted space
/// would split one file into two arguments).
enum ShellQuoting {
    static func quote(_ value: String) -> String {
        if !value.isEmpty,
           value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func commandLine(_ argv: [String]) -> String? {
        guard !argv.isEmpty else { return nil }
        return argv.map(quote).joined(separator: " ")
    }
}
