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
        let ssh = standInSSH()
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: configReads, stateDirectory: { state },
                                     makeTest: { RemoteHostComposition.connectionTest(for: $0, stateDirectory: $1, sshPath: ssh) })
        let factory = FakeTerminalSurfaceFactory()
        let app = AppModel(surfaceFactory: factory, database: try TempleDB.inMemory(), settings: SettingsStore(defaults: defaults),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence(), remoteHosts: hosts)
        return (app, factory)
    }

    /// A stand-in ssh, so no test reads the user's real ~/.ssh/config:
    /// `-G` answers a fixed resolution, `-O check` finds no master, anything
    /// else exits 0 having done nothing.
    func standInSSH() -> String {
        let path = "/private/tmp/temple-hosts-ssh-\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let script = """
        #!/bin/sh
        for a; do
          [ "$a" = "-G" ] && { printf 'user mentes\\nhostname 10.0.0.2\\nport 22\\n'; exit 0; }
          [ "$a" = "-O" ] && { echo "Control socket connect: No such file or directory" >&2; exit 255; }
        done
        exit 0
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
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
    /// around it; when it ends, whatever its status, the verdict is whether
    /// a master is up on Temple's socket (here none: ssh -O check on an
    /// empty socket path, local); closing the sheet tears the terminal down.
    func testTheTestSheetRunsSSHAndAsksForTheMasterWhenItEnds() throws {
        let (app, factory) = try app(enabled: true, records: [.config("box")]) { [] }
        let test = try XCTUnwrap(app.remoteHosts.startTest(for: "box"))
        var closed = false
        let sheet = ConnectionTestSheet(test: test, surfaceFactory: factory, appearance: .default,
                                        onTestAgain: {}, onClose: { closed = true })
        let window = render(sheet, size: NSSize(width: 680, height: 520))
        let started = Date().addingTimeInterval(10)
        while factory.created.last?.startedCommand == nil, Date() < started { spin(0.05) }
        let surface = try XCTUnwrap(factory.created.last)
        let argv = try XCTUnwrap(surface.startedCommand?.argv)
        XCTAssertEqual(argv, test.surfaceArgv)
        XCTAssertEqual(argv.first, "/usr/bin/env")
        XCTAssertTrue(argv[1].hasPrefix("/private/tmp/temple-hosts-ssh-"), argv[1])
        XCTAssertFalse(argv.contains("/bin/sh"), "no wrapper")
        XCTAssertTrue(argv.contains("ControlMaster=auto"))
        XCTAssertEqual(argv.suffix(3), ["--", "box", "true"])
        XCTAssertGreaterThan(surface.focusCount, 0, "the terminal takes the keyboard: ssh may ask")
        XCTAssertEqual(test.phase, .connecting)

        surface.simulateExit(status: 0)
        let deadline = Date().addingTimeInterval(10)
        while test.phase == .connecting, Date() < deadline { spin(0.05) }
        XCTAssertEqual(test.phase, .failed, "exit 0 is not a connection: no master, no checks")
        XCTAssertEqual(test.failure?.message, "Couldn't connect. See ssh's message above.")
        XCTAssertEqual(app.remoteHosts.statusLine(for: "box"), "Couldn't connect. Test the connection to see ssh's message.")
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
        let ssh = standInSSH()
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] }, stateDirectory: { state },
                                     makeTest: { RemoteHostComposition.connectionTest(for: $0, stateDirectory: $1, sshPath: ssh) })
        let test = try XCTUnwrap(hosts.startTest(for: "box"))
        let factory = FakeTerminalSurfaceFactory()
        let window = render(ConnectionTestSheet(test: test, surfaceFactory: factory, appearance: .default,
                                                onTestAgain: {}, onClose: {}), size: NSSize(width: 680, height: 520))
        let deadline = Date().addingTimeInterval(10)
        while test.phase == .connecting, Date() < deadline { spin(0.05) }
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
