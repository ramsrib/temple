import XCTest
import Foundation
import TempleCore
@testable import TempleUI

/// Phase 0 of remote (docs/designs/remote-ssh.md): the Hosts list, the
/// registry rebuilt from it, and the flag that keeps all of it dark.
@MainActor
final class RemoteHostsTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func hostsJSON(_ records: [RemoteHostRecord]) -> Data { RemoteHostList(records: records).encode() }

    private let added = RemoteHostRecord(name: "added-box", source: .temple, address: "10.0.0.2", user: "me", port: 2222)

    // MARK: Flag off

    /// Both `@main` entry points build the model through the same
    /// initializer, with nothing remote passed in, so what this file proves
    /// about that initializer holds for the shipped `.app` and for `make
    /// demo` alike (AGENTS.md, "Two entry points").
    func testBothEntryPointsBuildTheModelTheSameWayAndNameNothingRemote() throws {
        for relative in ["Sources/Temple/TempleApp.swift", "App/TempleApp.swift"] {
            let text = try String(contentsOf: Self.repo.appendingPathComponent(relative), encoding: .utf8)
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertTrue(flat.contains("return AppModel(surfaceFactory: GhosttyTerminalSurfaceFactory(configDirectory: TempleState.directory), database: database)"),
                          "\(relative) must build the model exactly as the other entry point does")
            XCTAssertEqual(flat.components(separatedBy: "AppModel(").count, 2, "\(relative): one model, built once")
            for word in ["hostRegistry", "remoteHosts", "RemoteHost", "TempleRemoteHost", "temple.feature"] {
                XCTAssertFalse(text.contains(word), "\(relative) names \(word)")
            }
        }
    }

    /// The model as the entry points build it, with the flag absent (its
    /// default): one host, one engine, nothing executed, no socket
    /// directory and no remote store, even with hosts in the list.
    func testFlagOffRegistersNoRemoteHostAndRunsNothing() async throws {
        let launches = RemoteHostComposition.processLaunches
        let stateDirectory = TempleState.directory
        let socketDirectory = stateDirectory.appendingPathComponent("ssh")
        let socketsBefore = FileManager.default.fileExists(atPath: socketDirectory.path)

        // Exactly the entry points' call: surface factory and database only.
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try TempleDB.inMemory())
        XCTAssertFalse(app.remoteHosts.isEnabled, "the flag defaults to off")
        XCTAssertEqual(app.hostRegistry.entries.map(\.source.host), [.local])
        XCTAssertEqual(app.engineSet.engines.map(\.host), [.local])
        app.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.hostRegistry.entries.count, 1)
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches, "the exec seam ran nothing")
        XCTAssertEqual(FileManager.default.fileExists(atPath: socketDirectory.path), socketsBefore, "no socket directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("remote-state.sqlite").path))

        // Hosts stored, flag still off: nothing registered, nothing read.
        let defaults = Fixture.uniqueDefaults()
        defaults.set(hostsJSON([.config("masterblaster-mentes"), added]), forKey: RemoteHostsModel.hostsKey)
        var configReads = 0
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { configReads += 1; return ["x"] })
        let dark = AppModel(database: try TempleDB.inMemory(), settings: SettingsStore(defaults: defaults),
                            hostRegistry: Fixture.hostsWithoutFolderEvidence(), remoteHosts: hosts)
        XCTAssertEqual(dark.hostRegistry.entries.count, 1)
        XCTAssertEqual(dark.engineSet.engines.count, 1)
        XCTAssertEqual(hosts.records, [])
        hosts.loadConfigAliases()
        hosts.setConfigHost("jetson-mentes", enabled: true)
        hosts.save(added, editing: nil)
        hosts.remove("masterblaster-mentes")
        XCTAssertEqual(configReads, 0)
        XCTAssertNil(hosts.startTest(for: "masterblaster-mentes"))
        XCTAssertEqual(dark.hostRegistry.entries.count, 1)
        XCTAssertEqual(defaults.data(forKey: RemoteHostsModel.hostsKey), hostsJSON([.config("masterblaster-mentes"), added]),
                       "a dark build never rewrites the list")
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches)
    }

    func testOnlyAnExplicitTrueTurnsTheFlagOn() {
        for (value, expected) in [(nil, false), (false as Any?, false), ("true" as Any?, false), (1 as Any?, true), (true as Any?, true)] {
            let defaults = Fixture.uniqueDefaults()
            if let value { defaults.set(value, forKey: RemoteHostsModel.featureKey) }
            XCTAssertEqual(RemoteHostsModel.featureEnabled(in: defaults), expected, String(describing: value))
        }
        XCTAssertEqual(RemoteHostsModel.featureKey, "temple.feature.remoteHosts")
        XCTAssertEqual(RemoteHostsModel.hostsKey, "temple.settings.remoteHosts")
    }

    // MARK: Flag on

    private func enabledDefaults(_ records: [RemoteHostRecord]) -> UserDefaults {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(true, forKey: RemoteHostsModel.featureKey)
        defaults.set(hostsJSON(records), forKey: RemoteHostsModel.hostsKey)
        return defaults
    }

    /// Enabled hosts are registered whether or not they were tested, with
    /// an engine each; registering runs nothing; the list's changes rebuild
    /// the registry and the local entry is never touched.
    func testEnabledHostsAreRegisteredUntestedAndFollowTheList() async throws {
        let launches = RemoteHostComposition.processLaunches
        let defaults = enabledDefaults([.config("masterblaster-mentes"), added])
        let app = AppModel(database: try TempleDB.inMemory(), settings: SettingsStore(defaults: defaults),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        let localEngine = try XCTUnwrap(app.engineSet.engine(for: .local))
        XCTAssertEqual(app.hostRegistry.entries.map(\.source.host.rawValue), ["", "masterblaster-mentes", "added-box"])
        XCTAssertEqual(app.engineSet.engines.map(\.host.rawValue), ["", "masterblaster-mentes", "added-box"])
        let remote = try XCTUnwrap(app.hostRegistry.entry(for: HostID(rawValue: "added-box")))
        XCTAssertEqual(remote.launcher.availability(.claude), .available, "untested is not unavailable")
        XCTAssertThrowsError(try remote.launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "x"),
                                                                         directory: "/home/me", host: remote.source.host)))
        app.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches, "registration and startup run nothing")

        app.remoteHosts.remove("masterblaster-mentes")
        XCTAssertEqual(app.hostRegistry.entries.map(\.source.host.rawValue), ["", "added-box"])
        XCTAssertEqual(app.engineSet.engines.map(\.host.rawValue), ["", "added-box"])
        app.remoteHosts.setConfigHost("jetson-mentes", enabled: true)
        XCTAssertEqual(app.hostRegistry.entries.map(\.source.host.rawValue), ["", "added-box", "jetson-mentes"])
        XCTAssertEqual(app.engineSet.engines.map(\.host.rawValue), ["", "added-box", "jetson-mentes"])
        var edited = added
        edited.port = 22
        app.remoteHosts.save(edited, editing: "added-box")
        XCTAssertEqual(app.hostRegistry.entries.count, 3, "an edit keeps the host's identity and entry")
        XCTAssertTrue(app.engineSet.engine(for: .local).map { $0 === localEngine } ?? false, "this Mac's engine is untouched")
        XCTAssertEqual(RemoteHostList.decode(defaults.data(forKey: RemoteHostsModel.hostsKey)).records,
                       [edited, .config("jetson-mentes")])
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches)
    }

    /// A test's findings drive availability: only a connected test that saw
    /// a CLI or tmux fail proves anything. An edit forgets them.
    func testAvailabilityComesOnlyFromAProvenFailure() throws {
        let defaults = enabledDefaults([added])
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] })
        XCTAssertEqual(hosts.statusLine(for: "added-box"), "Not tested yet. Test the connection to check this host.")
        hosts.recordSummary(HostTestSummary(failure: .other(firstLine: "ssh: connect to host 10.0.0.2 port 2222: Connection refused")),
                            for: "added-box")
        XCTAssertEqual(hosts.availability(of: "added-box", agent: .claude), .available, "couldn't connect proves nothing")
        XCTAssertEqual(hosts.statusLine(for: "added-box"), "Couldn't connect: ssh: connect to host 10.0.0.2 port 2222: Connection refused.")
        hosts.recordSummary(HostTestSummary(connectedAs: "me@10.0.0.2", claude: .missing, tmux: .missing), for: "added-box")
        XCTAssertEqual(hosts.availability(of: "added-box", agent: .claude), .unavailable(reason: "No claude on PATH."))
        XCTAssertEqual(hosts.availability(of: "added-box", agent: .codex),
                       .unavailable(reason: "No tmux on this host. Install tmux 3.2 or newer to start sessions here."))
        hosts.save(added, editing: "added-box")
        XCTAssertEqual(hosts.availability(of: "added-box", agent: .claude), .available)
        XCTAssertEqual(hosts.statusLine(for: "added-box"), HostTestSummary.notTested)
    }

    /// Writes are read-modify-write of one key: an entry stored after this
    /// model loaded (another Temple on the domain) survives a later write,
    /// and one this build cannot read is kept. (Not a cross-process
    /// transaction: two writes in the same instant can still lose one.)
    func testWritesKeepWhatOthersStored() throws {
        let defaults = enabledDefaults([added])
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] })
        // Another Temple on the same domain adds a host after this one loaded.
        var stored = RemoteHostList.decode(defaults.data(forKey: RemoteHostsModel.hostsKey))
        stored.records.append(.config("other-process"))
        stored.unreadable.append(Data(#"{"source":"future"}"#.utf8))
        defaults.set(stored.encode(), forKey: RemoteHostsModel.hostsKey)
        hosts.setConfigHost("jetson-mentes", enabled: true)
        let after = RemoteHostList.decode(defaults.data(forKey: RemoteHostsModel.hostsKey))
        XCTAssertEqual(after.records.map(\.name), ["added-box", "other-process", "jetson-mentes"])
        XCTAssertEqual(after.unreadable.count, 1)
        XCTAssertEqual(hosts.records.map(\.name), ["added-box", "other-process", "jetson-mentes"])
    }

    func testConfigAliasesAreReadOnlyOnRequest() {
        var reads = 0
        let hosts = RemoteHostsModel(defaults: enabledDefaults([]), readConfigAliases: { reads += 1; return ["box", "jetson-mentes"] })
        XCTAssertNil(hosts.configAliases)
        XCTAssertEqual(reads, 0, "constructing the model reads no ssh config")
        hosts.loadConfigAliases()
        XCTAssertEqual(hosts.configAliases, ["box", "jetson-mentes"])
        XCTAssertEqual(reads, 1)
    }

    /// The flag on with no hosts, over a database on disk: reordering,
    /// archiving and restoring local projects creates no remote store. Once
    /// a host's project has an order, a local reorder still clears it.
    func testWithNoHostsLocalProjectChangesCreateNoRemoteStore() throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-no-remote-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let db = try TempleDB(path: root.appendingPathComponent("temple.sqlite"))
        Fixture.join([Fixture.row("a", project: "/p/a"), Fixture.row("b", project: "/p/b")], to: db)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: db,
                           settings: SettingsStore(defaults: enabledDefaults([])),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        XCTAssertTrue(app.remoteHosts.isEnabled)
        XCTAssertEqual(app.databaseDirectory?.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        let store = root.appendingPathComponent("remote-state.sqlite")
        let a = ProjectKey(host: .local, path: "/p/a"), b = ProjectKey(host: .local, path: "/p/b")
        app.moveProject(b, before: a)
        XCTAssertEqual(app.overlay.projectKeyOrder.prefix(2), [b, a])
        app.archiveProject(a, undoManager: nil)
        app.restoreProject(a, undoManager: nil)
        app.moveProject(a, before: b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "no host, no remote store")

        // A host's project with an order: the store exists, and a reorder
        // that leaves no host's project placed clears its position.
        let remote = ProjectKey(host: HostID(rawValue: "box"), path: "/p/a")
        let persisting = try XCTUnwrap(app.overlay.remoteProjectState)
        persisting.setOrder([(remote, 0)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertEqual(persisting.projectStates().first { $0.key == remote }?.position, 0)
        persisting.setOrder([])
        XCTAssertNil(persisting.projectStates().first { $0.key == remote }?.position, "an empty order still clears")
    }
}
