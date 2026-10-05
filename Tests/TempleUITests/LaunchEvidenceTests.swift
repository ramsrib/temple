import XCTest
@testable import TempleCore
@testable import TempleUI
import TempleTerminalAPI

/// What a launch may claim about where it ran (ADR-029, Track B D4/E4): a
/// folder is recorded tab-sourced only when the launch itself reports
/// entering it, after a started spawn; a launcher failure is shown however
/// long the process lived; nothing is inferred from exit codes or from
/// `start()` returning.
@MainActor
final class LaunchEvidenceTests: XCTestCase {
    private func model(_ launcher: any HostLauncher, factory: FakeTerminalSurfaceFactory? = nil)
        -> (OpenSessionsModel, FakeTerminalSurfaceFactory) {
        let factory = factory ?? FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in launcher })
        model.earlyExitGraceSeconds = 0   // every exit is "late": only a launcher failure keeps a tab
        return (model, factory)
    }

    func testAHostThatCannotReportRecordsNothingEvenAfterASuccessfulStart() throws {
        let launcher = ScriptedLauncher(reports: false)
        let (model, factory) = model(launcher)
        var recorded: [String] = []
        model.launchDirectoryHandler = { _, _, path in recorded.append(path) }
        model.openSession(Fixture.session("s", project: "/p"))
        model.drainLaunchResults()
        XCTAssertEqual(factory.created.count, 1)
        XCTAssertEqual(model.activeTab?.activity, .running)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertNil(model.activeTab?.launchObservation?.directory)
    }

    func testTheFolderIsRecordedOnlyAfterTheSpawnStartsAndOnlyWhenReported() throws {
        let launcher = ScriptedLauncher()
        let (model, _) = model(launcher)
        var recorded: [String] = []
        model.launchDirectoryHandler = { _, _, path in recorded.append(path) }
        // A report that is available before the spawn starts is held, not lost and not early.
        launcher.queuedBeforeStart = [.directoryEstablished("/p")]
        model.openSession(Fixture.session("s", project: "/p"))
        XCTAssertEqual(recorded, ["/p"])
        XCTAssertEqual(model.activeTab?.launchObservation?.directory, "/p")
        let source = try XCTUnwrap(launcher.sources.last)
        XCTAssertFalse(source.stopped)
    }

    func testAFailedStartRecordsNothingAndReleasesTheLaunch() throws {
        let launcher = ScriptedLauncher()
        let factory = FakeTerminalSurfaceFactory()
        factory.configure = { $0.startError = CocoaError(.executableNotLoadable) }
        let (model, _) = model(launcher, factory: factory)
        var recorded: [String] = []
        model.launchDirectoryHandler = { _, _, path in recorded.append(path) }
        launcher.queuedBeforeStart = [.directoryEstablished("/p")]
        model.openSession(Fixture.session("s", project: "/p"))
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(try XCTUnwrap(launcher.sources.last).stopped)
        XCTAssertTrue(model.activeTab?.commandWasSuspect ?? false)
    }

    func testALauncherFailureKeepsTheTabWithItsReasonHoweverLateTheExit() throws {
        let launcher = ScriptedLauncher()
        let (model, factory) = model(launcher)
        model.openSession(Fixture.session("s", project: "/p"))
        let tab = try XCTUnwrap(model.activeTab)
        let source = try XCTUnwrap(launcher.sources.last)
        source.push(.failed(.cdFailed, message: "Temple couldn't enter the folder /p."))
        source.notifyNow()
        try XCTUnwrap(factory.created.last).simulateExit(status: 1)
        XCTAssertTrue(model.tabs.contains { $0.id == tab.id }, "not auto-closed")
        XCTAssertEqual(tab.launchFailure?.category, .cdFailed)
        XCTAssertEqual(tab.activity, .exited(status: 1))
        XCTAssertFalse(tab.commandWasSuspect, "the command was not at fault")
        XCTAssertTrue(source.stopped, "the launch is over and its marker gone")
    }

    /// The record can land without its notification having been delivered
    /// yet; the exit reads it synchronously before deciding.
    func testTheExitDrainsAReportThatHasNotBeenNotifiedYet() throws {
        let launcher = ScriptedLauncher()
        let (model, factory) = model(launcher)
        model.openSession(Fixture.session("s", project: "/p"))
        let tab = try XCTUnwrap(model.activeTab)
        try XCTUnwrap(launcher.sources.last).push(.failed(.cdFailed, message: "No folder."))
        try XCTUnwrap(factory.created.last).simulateExit(status: 1)
        XCTAssertTrue(model.tabs.contains { $0.id == tab.id })
        XCTAssertEqual(tab.launchFailure?.message, "No folder.")
    }

    func testAnOrdinaryExitAfterTheFolderWasEnteredClosesAsBefore() throws {
        let launcher = ScriptedLauncher()
        let (model, factory) = model(launcher)
        model.openSession(Fixture.session("s", project: "/p"))
        try XCTUnwrap(launcher.sources.last).push(.directoryEstablished("/p"))
        try XCTUnwrap(factory.created.last).simulateExit(status: 1)
        XCTAssertTrue(model.tabs.isEmpty, "an agent that ran and exited closes its tab")
        XCTAssertTrue(try XCTUnwrap(launcher.sources.last).stopped)
    }

    func testAClosedTabsLaunchIsReleasedAndItsLateReportsGoNowhere() throws {
        let launcher = ScriptedLauncher()
        let (model, _) = model(launcher)
        var recorded: [String] = []
        model.launchDirectoryHandler = { _, _, path in recorded.append(path) }
        model.openSession(Fixture.session("s", project: "/p"))
        let tab = try XCTUnwrap(model.activeTab)
        let source = try XCTUnwrap(launcher.sources.last)
        let channel = try XCTUnwrap(tab.launchResult)
        model.closeTab(tab.id)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(source.stopped)
        XCTAssertTrue(channel.isClosed)
        source.push(.directoryEstablished("/p"))
        source.notifyNow()
        channel.drain()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testCodexAdoptionRecordsTheReportedFolderWhicheverComesFirst() throws {
        for reportFirst in [true, false] {
            let launcher = ScriptedLauncher()
            let (model, _) = model(launcher)
            var recorded: [String: String] = [:]
            model.launchDirectoryHandler = { id, _, path in recorded[id] = path }
            let tab = model.newSession(agent: .codex, project: Fixture.key("/p"))
            let source = try XCTUnwrap(launcher.sources.last)
            if reportFirst { source.push(.directoryEstablished("/p")); source.notifyNow() }
            XCTAssertTrue(recorded.isEmpty, "no id yet")
            model.adopt(sessionID: "codex-id", for: tab.id)
            if !reportFirst {
                XCTAssertTrue(recorded.isEmpty, "adopted before the launch reported: nothing to record yet")
                source.push(.directoryEstablished("/p")); source.notifyNow()
            }
            XCTAssertEqual(recorded, ["codex-id": "/p"], "reportFirst=\(reportFirst)")
        }
    }

    func testABlameVerdictComesFromTheHostsAvailability() throws {
        let launcher = ScriptedLauncher()
        launcher.available = .unavailable(reason: "not found")
        let (model, factory) = model(launcher)
        model.earlyExitGraceSeconds = 60
        model.openSession(Fixture.session("s", project: "/p"))
        let tab = try XCTUnwrap(model.activeTab)
        try XCTUnwrap(factory.created.last).simulateExit(status: 127)
        XCTAssertTrue(tab.commandWasSuspect)
        launcher.available = .available
        XCTAssertTrue(tab.commandWasSuspect, "frozen at death")
    }

    func testALauncherThatProvesTheFolderGoneSpawnsNothing() throws {
        let launcher = ScriptedLauncher()
        launcher.missing = true
        let (model, factory) = model(launcher)
        model.openSession(Fixture.session("s", project: "/gone"))
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertEqual(model.activeTab?.launchPreparationError, "The folder /gone no longer exists.")
        XCTAssertEqual(model.activeTab?.activity, .exited(status: -1))
    }

    func testTheHeaderShowsTheAgentsArgvNotTheWrapper() throws {
        let markers = URL(fileURLWithPath: "/private/tmp/temple-markers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markers) }
        let launcher = LocalHostLauncher(binaryPath: { _ in "/bin/claude" }, folderEvidence: { _ in .unknown }, markerDirectory: markers)
        let (model, factory) = model(launcher)
        model.openSession(Fixture.session("s", project: "/p"))
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(tab.displayArgv, ["/bin/claude", "--resume", "s"])
        XCTAssertEqual(tab.command?.argv.first, "/usr/bin/env")
        XCTAssertEqual(factory.created.last?.startedCommand?.agentArgv, tab.displayArgv)
        model.closeTab(tab.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: markers.path), [], "closing the tab removed its marker")
    }

    // MARK: The local marker

    func testTheMarkerReadsCompleteRecordsOnlyAndEachOnce() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/temple-markers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = try XCTUnwrap(LocalLaunchMarker(directory: directory, folder: "/f"))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: marker.path))
        handle.write(Data("ok".utf8))
        XCTAssertEqual(marker.poll(), [], "a record still being written waits for its newline")
        handle.write(Data("\nfailed\tcd\t1\nunknown\n".utf8))
        let events = marker.poll()
        XCTAssertEqual(events.first, .directoryEstablished("/f"))
        guard case .failed(.cdFailed, _) = events.last, events.count == 2 else { return XCTFail("\(events)") }
        XCTAssertEqual(marker.poll(), [], "coalesced notifications deliver nothing twice")
        try handle.close()
        marker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTheMarkerNotifiesWhenTheWrapperWrites() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/temple-markers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = try LocalHostLauncher(folderEvidence: { _ in .unknown }, markerDirectory: directory)
            .prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "x"), directory: "/f", host: .local))
        let channel = try XCTUnwrap(launch.result)
        let delivered = expectation(description: "event")
        var events: [LaunchEvent] = []
        channel.onEvent = { event in
            events.append(event)
            if case .directoryEstablished = event { delivered.fulfill() }
        }
        let marker = try XCTUnwrap(launch.command.launchMarker)
        // What the shell's `printf 'ok\n' > "$2"` does: truncate, write.
        try Data("ok\n".utf8).write(to: URL(fileURLWithPath: marker))
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(events, [.directoryEstablished("/f")])
        channel.finish()
        XCTAssertEqual(events, [.directoryEstablished("/f"), .finished])
        channel.finish()
        channel.cancel()
        XCTAssertEqual(events.count, 2, "finishing twice reports nothing twice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testTheLocalLaunchersAvailabilityIsTheToolchainsShortReason() {
        let fresh = ToolchainModel(resolve: { ToolchainResolution(agent: $0, installs: [], chosen: nil) },
                                   probe: { _, _ in (version: "1.2.3", failure: nil, details: nil) })
        XCTAssertEqual(fresh.launchAvailability(.claude), .available, "unknown is not a failure")
        let launcher = LocalHostLauncher(availability: { $0 == .codex ? .unavailable(reason: "not found") : .available }, folderEvidence: { _ in .unknown })
        XCTAssertEqual(launcher.availability(.codex), .unavailable(reason: "not found"))
        XCTAssertEqual(launcher.availability(.claude), .available)
    }
}

/// A launcher whose result channel the test drives.
@MainActor
private final class ScriptedLauncher: HostLauncher {
    var reports = true
    var missing = false
    var available: LaunchAvailability = .available
    var queuedBeforeStart: [LaunchEvent] = []
    private(set) var sources: [ScriptedSource] = []
    init(reports: Bool = true) { self.reports = reports }
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        if missing { throw HostLaunchError.directoryMissing(spec.directory) }
        let argv = spec.agent.resumeArgv(sessionID: "x")
        guard reports else { return AgentLaunch(command: TerminalCommand(argv: argv, cwd: spec.directory), displayArgv: argv, result: nil) }
        let source = ScriptedSource()
        sources.append(source)
        let channel = LaunchResultChannel(source: source)
        for event in queuedBeforeStart { source.push(event) }
        source.notifyNow()
        return AgentLaunch(command: TerminalCommand(argv: argv, cwd: spec.directory), displayArgv: argv, result: channel)
    }
    func availability(_ agent: Agent) -> LaunchAvailability { available }
}

@MainActor
private final class ScriptedSource: LaunchResultSource {
    private var pending: [LaunchEvent] = []
    private var notify: (@MainActor () -> Void)?
    private(set) var stopped = false
    func start(notify: @escaping @MainActor () -> Void) { self.notify = notify }
    func poll() -> [LaunchEvent] { defer { pending.removeAll() }; return pending }
    func stop() { stopped = true; notify = nil }
    func push(_ event: LaunchEvent) { pending.append(event) }
    func notifyNow() { notify?() }
}

/// This Mac's launcher proves a folder gone from its own `stat(2)` before
/// anything spawns (it replaced the old synchronous directory-evidence path).
@MainActor
final class LocalFolderEvidenceTests: XCTestCase {
    func testPrepareRefusesAFolderThisMacProvesGoneAndOnlyThatOne() throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = LocalHostLauncher(binaryPath: { _ in "/bin/claude" }, markerDirectory: root.appendingPathComponent("markers"))
        let gone = root.appendingPathComponent("gone").path
        XCTAssertThrowsError(try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "s"), directory: gone, host: .local))) {
            XCTAssertEqual($0 as? HostLaunchError, .directoryMissing(gone))
        }
        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        XCTAssertThrowsError(try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "s"), directory: file.path, host: .local)))
        let present = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "s"), directory: root.path, host: .local))
        present.result?.cancel()
        XCTAssertEqual(LocalHostLauncher.statEvidence(root.path), .exists)
        XCTAssertEqual(LocalHostLauncher.statEvidence(gone), .missing)
        XCTAssertEqual(LocalHostLauncher.statEvidence(file.path + "/below"), .missing, "ENOTDIR proves it gone")
    }

    /// The same answer as the session source: a folder on a drive that is
    /// not plugged in, reached directly or through a symlink, is not gone.
    /// The launch goes ahead behind the wrapper, whose own `cd` decides.
    func testPrepareDoesNotCallAFolderOnAnUnpluggedVolumeGone() throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = LocalHostLauncher(binaryPath: { _ in "/bin/claude" }, markerDirectory: root.appendingPathComponent("markers"))
        let volume = "/Volumes/temple-unmounted-\(UUID().uuidString)"
        let link = root.appendingPathComponent("drive")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: volume)
        for folder in [volume + "/project", link.appendingPathComponent("project").path] {
            XCTAssertEqual(LocalHostLauncher.statEvidence(folder), .unknown, folder)
            let launch = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "s"), directory: folder, host: .local))
            XCTAssertEqual(launch.command.launchFolder, folder, "the wrapper still enters it, or reports")
            launch.result?.cancel()
        }
    }
}
