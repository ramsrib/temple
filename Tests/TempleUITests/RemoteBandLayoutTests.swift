import AppKit
import SwiftUI
import XCTest
import TempleCore
import TempleTestSupport
@testable import TempleUI

/// The remote bands laid out in a window of their own, in process: nothing
/// of the app is launched or driven.
@MainActor
final class RemoteBandLayoutTests: XCTestCase {
    let hostID = HostID(rawValue: "masterblaster-mentes")

    private func settle(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The ended band laid out in a window `width` wide: every AppKit view
    /// SwiftUI backs it with, framed in the window (y up), the controls
    /// (each control's focus ring) and the selectable sentence.
    private struct Laid {
        let controls: [NSRect]
        let sentence: NSRect
        let sentenceText: String
        let window: NSWindow
    }

    private func layEndedBand(width: CGFloat) async throws -> Laid {
        let remote = FakeRemoteHost(hostID.rawValue)
        let local = Fixture.hostsWithoutFolderEvidence().entries[0]
        let hosts = HostRegistry(entries: [local, .init(source: FakeHostSource(host: hostID), launcher: remote)])
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try TempleDB.inMemory(),
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()), hostRegistry: hosts)
        app.start()
        remote.pending = [.init(handle: "p7", directory: "/home/u/p", ended: true, typed: true)]
        let prompt = "count slowly to twenty out loud, then reply with the word ok and nothing else at all"
        remote.suggestionsResult = .candidates([RemoteSuggestion(rolloutPath: "/r/c7.jsonl", sessionID: "c7",
                                                                 firstPrompt: prompt, startedAt: Date(), directory: "/home/u/p")])
        app.openSessions.remoteTabs.restorePending(hosts: [hostID])
        await settle { app.openSessions.tabs.contains { $0.remote?.handle == "p7" } }
        let chip = try XCTUnwrap(app.openSessions.tabs.first { $0.remote?.handle == "p7" })
        app.openSessions.activate(chip)
        await settle { chip.remote?.suggestions.count == 1 }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: MainContentView().environmentObject(app))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()

        // SwiftUI builds no accessibility tree for a window nobody asks, so
        // this reads the AppKit views it backs the band with: each control's
        // focus ring, and the selectable sentence's text view.
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let all = views(hosting).filter { $0 !== hosting }.map { ($0, $0.convert($0.bounds, to: nil)) }
        let controls = all.filter { String(describing: type(of: $0.0)).contains("FocusRing") }.map(\.1)
        let texts = all.filter { String(describing: type(of: $0.0)).contains("Text") }
        let sentence = try XCTUnwrap(texts.max { $0.1.height < $1.1.height }, "the sentence")
        let string = (sentence.0 as? NSTextView)?.string
            ?? (sentence.0.accessibilityValue() as? String) ?? ""
        return Laid(controls: controls, sentence: sentence.1, sentenceText: string, window: window)
    }

    /// At a narrow window the ended band's sentence takes the band's width
    /// and wraps under itself; its answers sit on a row beneath it, leading,
    /// with Discard at the row's trailing edge, every control inside the
    /// window (Fable's visual round 3: beside a 5-line column they left a
    /// dead area). The host's name wraps whole: its hyphens are
    /// non-breaking (display only).
    func testTheEndedBandPutsItsAnswersUnderTheSentenceAtANarrowWidth() async throws {
        let width: CGFloat = 560
        let laid = try await layEndedBand(width: width)
        defer { laid.window.close() }
        XCTAssertGreaterThanOrEqual(laid.controls.count, 4, "Yes, Not this one, Start a new session, Discard")
        for frame in laid.controls {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "a control stays inside the window: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
            XCTAssertLessThanOrEqual(frame.maxY, laid.sentence.minY + 0.5, "the answers sit beneath the sentence: \(frame)")
        }
        XCTAssertGreaterThan(laid.sentence.height, 30, "it wraps under itself")
        XCTAssertGreaterThan(laid.sentence.width, width * 0.75, "at the band's width, not a column beside the answers")
        let first = try XCTUnwrap(laid.controls.map(\.minX).min())
        XCTAssertLessThan(abs(first - laid.sentence.minX), 8, "the answers start under the sentence")
        let last = try XCTUnwrap(laid.controls.map(\.maxX).max())
        XCTAssertGreaterThan(last, width - 40, "Discard sits at the trailing edge")
        XCTAssertTrue(laid.sentenceText.contains("masterblaster\u{2011}mentes"), laid.sentenceText)
        XCTAssertFalse(laid.sentenceText.contains("masterblaster-mentes"), laid.sentenceText)
        XCTAssertEqual(RemoteCopy.displayHost("a-b-c"), "a\u{2011}b\u{2011}c")
    }

    /// At a wide window the sentence and its answers share one line.
    func testTheEndedBandKeepsItsAnswersBesideTheSentenceWhenWide() async throws {
        let width: CGFloat = 2400
        let laid = try await layEndedBand(width: width)
        defer { laid.window.close() }
        XCTAssertGreaterThanOrEqual(laid.controls.count, 4)
        XCTAssertLessThan(laid.sentence.height, 30, "one line")
        for frame in laid.controls {
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            XCTAssertGreaterThan(frame.minX, laid.sentence.maxX - 0.5, "the answers follow it: \(frame)")
            XCTAssertGreaterThan(frame.maxY, laid.sentence.minY, "on its line: \(frame)")
        }
    }
}
