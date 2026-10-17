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

    /// At a narrow window the ended band's sentence wraps under itself: its
    /// answers stay beside it and Discard stays inside the band, never
    /// pushed past the edge.
    func testTheEndedBandWrapsItsSentenceAtANarrowWidth() async throws {
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

        let width: CGFloat = 560
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
        XCTAssertGreaterThanOrEqual(controls.count, 4, "Yes, Not this one, Start a new session, Discard")
        for frame in controls {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "a control stays inside the window: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
        }
        let sentence = try XCTUnwrap(all.filter { String(describing: type(of: $0.0)).contains("Text") }
            .map(\.1).max { $0.height < $1.height }, "the sentence")
        XCTAssertGreaterThan(sentence.height, 30, "it wraps under itself")
        XCTAssertLessThan(sentence.maxX, try XCTUnwrap(controls.map(\.minX).min()), "the answers follow it")
        window.close()
    }
}
