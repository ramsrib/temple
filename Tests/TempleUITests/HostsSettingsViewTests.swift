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
    private func app(records: [RemoteHostRecord] = [], configReads: @escaping () -> [String]) throws -> (AppModel, FakeTerminalSurfaceFactory) {
        let defaults = Fixture.uniqueDefaults()
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

    /// No flag: the Hosts card is there with no host enabled (the one
    /// remote surface then, and the way to add one), and the ssh config is
    /// read only once it is shown, never before.
    func testTheHostsCardIsAlwaysShownAndReadsTheConfigOnlyWhenShown() throws {
        var reads = 0
        let (empty, _) = try app { reads += 1; return ["box"] }
        XCTAssertEqual(reads, 0, "building the model reads no ssh config")
        XCTAssertNil(empty.remoteHosts.configAliases)
        let emptyWindow = render(SettingsView(settings: empty.settings).environmentObject(empty))
        spin()
        XCTAssertEqual(reads, 1, "with no host, the card is shown and reads ~/.ssh/config on appearing")
        XCTAssertEqual(empty.remoteHosts.configAliases, ["box"])
        XCTAssertEqual(empty.hostRegistry.entries.map(\.source.host), [.local], "showing the card registers nothing")
        emptyWindow.close()

        let (lit, _) = try app(records: [.config("box"),
            RemoteHostRecord(name: "added", source: .temple, address: "10.0.0.2", user: "me")]) { reads += 1; return ["box", "jetson-mentes"] }
        let window = render(SettingsView(settings: lit.settings).environmentObject(lit))
        spin()
        XCTAssertEqual(reads, 2, "the card read ~/.ssh/config once, on appearing")
        XCTAssertEqual(lit.remoteHosts.configAliases, ["box", "jetson-mentes"])
        window.close()
    }

    /// One "In use" list, whichever source a host came from, by name; the
    /// caption says where it came from, and an enabled alias the config no
    /// longer names says so, but only once the config has been read. The
    /// owner read "Added in Temple: No hosts added yet." as no hosts while a
    /// config host was on.
    func testInUseListsEveryEnabledHostByNameWithWhereItCameFrom() {
        let added = RemoteHostRecord(name: "build-box", source: .temple, address: "10.0.0.2", user: "me")
        let records: [RemoteHostRecord] = [.config("masterblaster-mentes"), added, .config("jetson-mentes")]
        XCTAssertEqual(HostsSettingsSection.inUse(records).map(\.name), ["build-box", "jetson-mentes", "masterblaster-mentes"])
        XCTAssertEqual(HostsSettingsSection.caption(for: added, configAliases: nil), .summary(added.summary))
        let aliases = ["masterblaster-mentes"]
        XCTAssertEqual(HostsSettingsSection.caption(for: .config("masterblaster-mentes"), configAliases: aliases), .sshConfig)
        XCTAssertEqual(HostsSettingsSection.Caption.sshConfig.text, "~/.ssh/config")
        XCTAssertEqual(HostsSettingsSection.caption(for: .config("jetson-mentes"), configAliases: aliases), .goneFromConfig)
        XCTAssertEqual(HostsSettingsSection.Caption.goneFromConfig.text, "No longer in ~/.ssh/config")
        XCTAssertEqual(HostsSettingsSection.caption(for: .config("jetson-mentes"), configAliases: nil), .sshConfig,
                       "nothing is known missing while the config is read")
        XCTAssertEqual(HostsSettingsSection.inUseEmpty, "No hosts in use.")
    }

    /// The card lists no host that is not in use: Add host… offers the
    /// config's unused aliases (a hand-added host with an alias's name
    /// takes it out too), or says disabled why there are none, then Enter
    /// details… and Edit ~/.ssh/config.
    func testAddHostOffersOnlyTheConfigsAliasesNotInUse() {
        typealias Entry = HostsSettingsSection.AddHostEntry
        let tail: [Entry] = [.divider, .enterDetails, .editConfig]
        let records: [RemoteHostRecord] = [.config("box"), RemoteHostRecord(name: "jetson", source: .temple, address: "a")]
        XCTAssertEqual(HostsSettingsSection.addHostMenu(configAliases: ["box", "jetson", "spare"], records: records),
                       [.alias("spare")] + tail)
        XCTAssertEqual(HostsSettingsSection.addHostMenu(configAliases: nil, records: records),
                       [.unavailable("Reading ~/.ssh/config\u{2026}")] + tail)
        XCTAssertEqual(HostsSettingsSection.addHostMenu(configAliases: [], records: []),
                       [.unavailable("No hosts in ~/.ssh/config")] + tail)
        XCTAssertEqual(HostsSettingsSection.addHostMenu(configAliases: ["box"], records: records),
                       [.unavailable("Every host in ~/.ssh/config is in use")] + tail)
        XCTAssertEqual(Entry.enterDetails.title, "Enter details\u{2026}")
        XCTAssertEqual(Entry.editConfig.title, "Edit ~/.ssh/config")
    }

    /// Choosing an alias turns it on, so it is in use and no longer offered;
    /// Turn off brings it back to the menu.
    func testChoosingAnAliasPutsItInUseAndTurnOffOffersItAgain() throws {
        let (app, _) = try app { ["box", "spare"] }
        let hosts = app.remoteHosts
        hosts.loadConfigAliases()
        hosts.setConfigHost("spare", enabled: true)
        XCTAssertEqual(HostsSettingsSection.inUse(hosts.records).map(\.name), ["spare"])
        XCTAssertEqual(HostsSettingsSection.offered(configAliases: hosts.configAliases, records: hosts.records), ["box"])
        hosts.setConfigHost("spare", enabled: false)
        XCTAssertEqual(HostsSettingsSection.inUse(hosts.records), [])
        XCTAssertEqual(HostsSettingsSection.offered(configAliases: hosts.configAliases, records: hosts.records), ["box", "spare"])
    }

    /// The sheet's terminal runs the user's ssh itself, nothing wrapped
    /// around it; when it ends, whatever its status, the verdict is whether
    /// a master is up on Temple's socket (here none: ssh -O check on an
    /// empty socket path, local); closing the sheet tears the terminal down.
    func testTheTestSheetRunsSSHAndAsksForTheMasterWhenItEnds() throws {
        let (app, factory) = try app(records: [.config("box")]) { [] }
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

    /// The sheet's terminal is given the app's appearance and applies it
    /// (the terminal runtime's theme follows only an apply, and with no tab
    /// open nothing else had applied it: a white terminal in a dark sheet).
    /// The terminal is 160 pt; the card's links do not repeat the host and
    /// its status line is a tertiary caption until a test proves a fault.
    func testTheTestSheetsTerminalAppliesTheAppsAppearance() throws {
        let (app, factory) = try app(records: [.config("box")]) { [] }
        let test = try XCTUnwrap(app.remoteHosts.startTest(for: "box"))
        let light = TerminalAppearance(fontSize: 13, colorScheme: .light)
        let window = render(ConnectionTestSheet(test: test, surfaceFactory: factory, appearance: light,
                                                onTestAgain: {}, onClose: {}), size: NSSize(width: 680, height: 520))
        let surface = try XCTUnwrap(factory.created.last)
        XCTAssertEqual(surface.appliedAppearances.first, light)
        XCTAssertEqual(ConnectionTestSheet.terminalHeight, 160)
        XCTAssertEqual(HostsSettingsSection.sessionsLink, "Sessions\u{2026}")
        XCTAssertEqual(HostStatusLine(text: "Not tested yet.", summary: nil).tone, .caption)
        window.contentView = nil
        window.close()
        app.remoteHosts.endTest(test)
        spin()
    }

    /// A socket directory Temple won't use: the sheet starts no terminal.
    func testNoTerminalStartsWhenTheTestCannotBePrepared() throws {
        let defaults = Fixture.uniqueDefaults()
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

    func testTheCheckingLineSaysConnectedOnlyOnceConfirmed() {
        XCTAssertEqual(ConnectionTestSheet.checkingLine(confirmed: false), "Checking the connection…")
        XCTAssertEqual(ConnectionTestSheet.checkingLine(confirmed: true), "Connected. Checking the host…")
    }

    /// Closing the sheet while ssh -G still runs: the start is cancelled,
    /// ssh -G with it, and no terminal or socket storage appears.
    func testClosingTheSheetDuringResolutionCancelsIt() throws {
        let tree = "/private/tmp/temple-hosts-resolve-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: tree + "/state", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tree) }
        let ssh = tree + "/ssh"
        try "#!/bin/sh\nfor a; do [ \"$a\" = -G ] && { echo $$ > \(tree)/pid; exec sleep 30; }; done\nexit 0\n"
            .write(toFile: ssh, atomically: true, encoding: .utf8)
        chmod(ssh, 0o755)
        let defaults = Fixture.uniqueDefaults()
        defaults.set(RemoteHostList(records: [.config("box")]).encode(), forKey: RemoteHostsModel.hostsKey)
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] },
                                     stateDirectory: { URL(fileURLWithPath: tree + "/state") },
                                     makeTest: { RemoteHostComposition.connectionTest(for: $0, stateDirectory: $1, sshPath: ssh) })
        let test = try XCTUnwrap(hosts.startTest(for: "box"))
        let factory = FakeTerminalSurfaceFactory()
        let window = render(ConnectionTestSheet(test: test, surfaceFactory: factory, appearance: .default,
                                                onTestAgain: {}, onClose: {}), size: NSSize(width: 680, height: 520))
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: tree + "/pid"), Date() < deadline { spin(0.05) }
        let pid = try XCTUnwrap(Int32(try String(contentsOfFile: tree + "/pid", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        window.contentView = nil
        window.close()
        hosts.endTest(test)
        spin(1.5)
        XCTAssertNotEqual(kill(pid, 0), 0, "ssh -G was ended with the sheet")
        XCTAssertNil(factory.created.last?.startedCommand, "no terminal started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree + "/state/ssh"), "no socket storage prepared")
    }

    func testTheFormSheetRenders() {
        let sheet = HostFormSheet(request: HostFormRequest(editing: RemoteHostRecord(name: "added", source: .temple, address: "a")),
                                  existing: ["added"], configAliases: []) { _, _ in }
        let window = render(sheet, size: NSSize(width: 520, height: 560))
        spin()
        window.close()
    }
}
