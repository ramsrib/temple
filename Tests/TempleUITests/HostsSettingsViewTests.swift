import AppKit
import SwiftUI
import XCTest
import TempleCore
import TempleTerminalAPI
@testable import TempleUI

/// The Hosts connection manager rendered in a window of its own, in
/// process: nothing of the app is launched or driven.
@MainActor
final class HostsSettingsViewTests: XCTestCase {
    private func app(enabled: Bool, records: [RemoteHostRecord] = [], configReads: @escaping () -> [String]) throws -> (AppModel, FakeTerminalSurfaceFactory) {
        let defaults = Fixture.uniqueDefaults()
        if enabled { defaults.set(true, forKey: RemoteHostsModel.featureKey) }
        defaults.set(RemoteHostList(records: records).encode(), forKey: RemoteHostsModel.hostsKey)
        let state = URL(fileURLWithPath: "/private/tmp/temple-hosts-view-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: configReads, stateDirectory: { state })
        let factory = FakeTerminalSurfaceFactory()
        let app = AppModel(surfaceFactory: factory, database: try TempleDB.inMemory(), settings: SettingsStore(defaults: defaults),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence(), remoteHosts: hosts)
        return (app, factory)
    }

    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 900, height: 1400)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testTheHostsCardAppearsOnlyWithTheFlagAndReadsTheConfigThen() throws {
        var reads = 0
        let (dark, _) = try app(enabled: false) { reads += 1; return ["box"] }
        let darkWindow = render(SettingsView(settings: dark.settings).environmentObject(dark))
        spin()
        XCTAssertEqual(reads, 0, "flag off: the Hosts card is absent and reads nothing")
        darkWindow.close()

        let (lit, _) = try app(enabled: true, records: [.config("box"),
            RemoteHostRecord(name: "added", source: .temple, address: "10.0.0.2", user: "me")]) { reads += 1; return ["box", "jetson-mentes"] }
        let window = render(SettingsView(settings: lit.settings).environmentObject(lit))
        spin()
        XCTAssertEqual(reads, 1, "the card read ~/.ssh/config once, on appearing")
        XCTAssertEqual(lit.remoteHosts.configAliases, ["box", "jetson-mentes"])
        window.close()
    }

    /// The sheet's terminal runs the user's ssh itself, nothing wrapped
    /// around it; its exit status is the connect's verdict; closing the
    /// sheet tears the terminal down.
    func testTheTestSheetRunsSSHAndReadsItsExit() throws {
        let (app, factory) = try app(enabled: true, records: [.config("box")]) { [] }
        let test = try XCTUnwrap(app.remoteHosts.startTest(for: "box"))
        var closed = false
        let sheet = ConnectionTestSheet(test: test, surfaceFactory: factory, appearance: .default,
                                        onTestAgain: {}, onClose: { closed = true })
        let window = render(sheet, size: NSSize(width: 680, height: 520))
        spin()
        let surface = try XCTUnwrap(factory.created.last)
        let argv = try XCTUnwrap(surface.startedCommand?.argv)
        XCTAssertEqual(argv, test.surfaceArgv)
        XCTAssertEqual(argv.first, "/usr/bin/env")
        XCTAssertTrue(argv[1].hasSuffix("/ssh"), argv[1])
        XCTAssertFalse(argv.contains("/bin/sh"), "no wrapper")
        XCTAssertTrue(argv.contains("ControlMaster=auto"))
        XCTAssertEqual(argv.suffix(3), ["--", "box", "true"])
        XCTAssertGreaterThan(surface.focusCount, 0, "the terminal takes the keyboard: ssh may ask")
        XCTAssertEqual(test.phase, .connecting)

        surface.simulateExit(status: 255)
        XCTAssertEqual(test.phase, .failed)
        XCTAssertEqual(test.failure?.message, "Couldn't connect. See ssh's message above.")
        XCTAssertEqual(app.remoteHosts.statusLine(for: "box"),
                       "Couldn't connect: ssh exited with status 255. Test the connection to see ssh's message.")
        XCTAssertFalse(closed)

        window.contentView = nil
        window.close()
        spin()
        XCTAssertTrue(surface.didTerminate)
        XCTAssertGreaterThan(surface.releaseCount, 0)
    }

    /// A socket directory Temple won't use: the sheet starts no terminal.
    func testNoTerminalStartsWhenTheTestCannotBePrepared() throws {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(true, forKey: RemoteHostsModel.featureKey)
        defaults.set(RemoteHostList(records: [.config("box")]).encode(), forKey: RemoteHostsModel.hostsKey)
        let state = URL(fileURLWithPath: "/private/tmp/temple-hosts-blocked-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        try Data("not a directory".utf8).write(to: state.appendingPathComponent("ssh"))
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] }, stateDirectory: { state })
        let test = try XCTUnwrap(hosts.startTest(for: "box"))
        let factory = FakeTerminalSurfaceFactory()
        let window = render(ConnectionTestSheet(test: test, surfaceFactory: factory, appearance: .default,
                                                onTestAgain: {}, onClose: {}), size: NSSize(width: 680, height: 520))
        spin()
        XCTAssertNil(factory.created.last?.startedCommand, "no ssh was started")
        XCTAssertEqual(test.phase, .failed)
        XCTAssertTrue(hosts.statusLine(for: "box").hasPrefix("Temple couldn't prepare the test: "))
        window.close()
    }

    func testTheFormSheetRenders() {
        let sheet = HostFormSheet(request: HostFormRequest(editing: RemoteHostRecord(name: "added", source: .temple, address: "a")),
                                  existing: ["added"], configAliases: []) { _, _ in }
        let window = render(sheet, size: NSSize(width: 520, height: 560))
        spin()
        window.close()
    }
}
