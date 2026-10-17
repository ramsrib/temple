import XCTest
import Foundation
import TempleCore
@testable import TempleUI

/// Phase 0 of remote (docs/designs/remote-ssh.md): the Hosts list and the
/// registry rebuilt from it. There is no flag: with no host enabled nothing
/// remote exists, and remote appears only for an enabled host.
@MainActor
final class RemoteHostsTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func hostsJSON(_ records: [RemoteHostRecord]) -> Data { RemoteHostList(records: records).encode() }

    private let added = RemoteHostRecord(name: "added-box", source: .temple, address: "10.0.0.2", user: "me", port: 2222)

    // MARK: No host enabled

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
            for word in ["hostRegistry", "remoteHosts", "RemoteHost", "TempleRemoteHost", "temple.feature", "temple.settings.remoteHosts"] {
                XCTAssertFalse(text.contains(word), "\(relative) names \(word)")
            }
        }
    }

    /// The model as the entry points build it, with no host in the list:
    /// one host, one engine, nothing executed, no ssh config read, no
    /// socket directory, no remote store (not even attached), and none of
    /// the remote UI's inputs: no ⌘N or launcher host rows, no shortcuts
    /// note, no sidebar notice, no pending chips. An old flag left in the
    /// settings domain changes none of it.
    func testWithNoHostNothingRemoteExistsOrRuns() async throws {
        let launches = RemoteHostComposition.processLaunches
        let stateDirectory = TempleState.directory
        let socketDirectory = stateDirectory.appendingPathComponent("ssh")
        let socketsBefore = FileManager.default.fileExists(atPath: socketDirectory.path)
        let storeBefore = FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("remote-state.sqlite").path)

        // Exactly the entry points' call: surface factory and database only.
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try TempleDB.inMemory())
        XCTAssertFalse(app.remoteHosts.hasHosts, "the host list starts empty")
        XCTAssertEqual(app.hostRegistry.entries.map(\.source.host), [.local])
        XCTAssertEqual(app.engineSet.engines.map(\.host), [.local])
        app.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.hostRegistry.entries.count, 1)
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches, "the exec seam ran nothing")
        XCTAssertEqual(FileManager.default.fileExists(atPath: socketDirectory.path), socketsBefore, "no socket directory")
        XCTAssertEqual(FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("remote-state.sqlite").path),
                       storeBefore, "no remote store")

        // The old flag's key, on, with an empty list: still nothing.
        let defaults = Fixture.uniqueDefaults()
        defaults.set(true, forKey: "temple.feature.remoteHosts")
        var configReads = 0
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { configReads += 1; return ["x"] })
        let root = URL(fileURLWithPath: "/private/tmp/temple-no-host-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let empty = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             database: try TempleDB(path: root.appendingPathComponent("temple.sqlite")),
                             settings: SettingsStore(defaults: defaults),
                             hostRegistry: Fixture.hostsWithoutFolderEvidence(), remoteHosts: hosts)
        empty.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(hosts.hasHosts)
        XCTAssertEqual(empty.hostRegistry.entries.map(\.source.host), [.local])
        XCTAssertEqual(empty.engineSet.engines.map(\.host), [.local])
        XCTAssertTrue(empty.remoteHostIDs.isEmpty)
        XCTAssertTrue(empty.remoteLaunchHosts.isEmpty, "no host rows in ⌘N or the launcher")
        XCTAssertNil(empty.remoteNotice, "no sidebar notice")
        XCTAssertNil(empty.overlay.remoteProjectState, "the remote store is not even attached")
        XCTAssertFalse(empty.openSessions.tabs.contains { $0.remote != nil }, "no pending chips")
        XCTAssertEqual(configReads, 0, "no ssh config read until the Hosts card is shown")
        XCTAssertNil(hosts.configAliases)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote-state.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ssh").path))
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches)
    }

    /// Enabling a host is what makes remote appear, and only for that host.
    func testEnablingAHostIsWhatMakesRemoteAppear() throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-first-host-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = Fixture.uniqueDefaults()
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] })
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                           database: try TempleDB(path: root.appendingPathComponent("temple.sqlite")),
                           settings: SettingsStore(defaults: defaults),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence(), remoteHosts: hosts)
        XCTAssertTrue(app.remoteLaunchHosts.isEmpty)
        hosts.setConfigHost("jetson-mentes", enabled: true)
        XCTAssertTrue(hosts.hasHosts)
        XCTAssertEqual(app.remoteLaunchHosts, [HostID(rawValue: "jetson-mentes")], "rows for that host only")
        XCTAssertNotNil(app.overlay.remoteProjectState, "its projects' masks have a place now")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote-state.sqlite").path),
                       "attached is not created: nothing written yet")
        hosts.remove("jetson-mentes")
        XCTAssertFalse(hosts.hasHosts)
        XCTAssertTrue(app.remoteLaunchHosts.isEmpty)
    }

    func testTheHostListKeyIsUnchangedAndTheOldFlagIsIgnored() {
        XCTAssertEqual(RemoteHostsModel.hostsKey, "temple.settings.remoteHosts")
        let defaults = Fixture.uniqueDefaults()
        defaults.set(false, forKey: "temple.feature.remoteHosts")
        defaults.set(hostsJSON([added]), forKey: RemoteHostsModel.hostsKey)
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] })
        XCTAssertEqual(hosts.records, [added], "a host is enabled whatever the old flag said")
        XCTAssertEqual(hosts.registeredHosts, [added])
    }

    // MARK: Hosts enabled

    private func enabledDefaults(_ records: [RemoteHostRecord]) -> UserDefaults {
        let defaults = Fixture.uniqueDefaults()
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

    /// No host, then a host with no project yet, over a database on disk: reordering,
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
        XCTAssertNil(app.overlay.remoteProjectState, "no host: the remote store is not attached")
        app.moveProject(ProjectKey(host: .local, path: "/p/b"), before: ProjectKey(host: .local, path: "/p/a"))
        app.moveProject(ProjectKey(host: .local, path: "/p/a"), before: ProjectKey(host: .local, path: "/p/b"))
        // A host enabled with no project of its own yet: local changes
        // still create no store.
        app.remoteHosts.setConfigHost("box", enabled: true)
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
