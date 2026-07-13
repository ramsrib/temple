import XCTest
@testable import TempleCore

final class ShellWordsTests: XCTestCase {

    func testPlainArguments() {
        XCTAssertEqual(ShellWords.split("--dangerously-skip-permissions"),
                       ["--dangerously-skip-permissions"])
        XCTAssertEqual(ShellWords.split("-a -b -c"), ["-a", "-b", "-c"])
        XCTAssertEqual(ShellWords.split(""), [])
        XCTAssertEqual(ShellWords.split("   "), [])
    }

    /// The bug this exists to kill: the old `split(separator: " ")` turned a flag
    /// with a spaced value into three broken arguments, quote marks and all, and the
    /// agent silently received nonsense.
    func testQuotedValuesSurviveAsOneArgument() {
        XCTAssertEqual(ShellWords.split(#"--append-system-prompt "be terse""#),
                       ["--append-system-prompt", "be terse"])
        XCTAssertEqual(ShellWords.split("--prompt 'hello world'"),
                       ["--prompt", "hello world"])
    }

    func testCollapsesRunsOfWhitespace() {
        XCTAssertEqual(ShellWords.split("  -a    -b\t-c  "), ["-a", "-b", "-c"])
    }

    func testEscapesAndMixedQuoting() {
        XCTAssertEqual(ShellWords.split(#"--path /tmp/a\ b"#), ["--path", "/tmp/a b"])
        XCTAssertEqual(ShellWords.split(#"--say "it's fine""#), ["--say", "it's fine"])
        XCTAssertEqual(ShellWords.split(#"--say 'say "hi"'"#), ["--say", #"say "hi""#])
        // A backslash is literal inside single quotes, as in a real shell.
        XCTAssertEqual(ShellWords.split(#"'a\b'"#), [#"a\b"#])
    }

    /// `""` is a real, empty argument — distinct from no argument at all.
    func testEmptyQuotedArgumentIsPreserved() {
        XCTAssertEqual(ShellWords.split(#"--name "" --x"#), ["--name", "", "--x"])
    }

    /// An unterminated quote shouldn't drop the text the user typed.
    func testUnterminatedQuoteKeepsTheContent() {
        XCTAssertEqual(ShellWords.split(#"--say "unclosed"#), ["--say", "unclosed"])
    }
}
