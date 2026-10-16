import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTerminalAPI

/// A host whose answers a test scripts: a small model of the run store, so
/// the tab side (open, exit, close, quit) is driven through the state table
/// (docs/designs/remote-ssh.md sections 3 and 5) without a network.
@MainActor
final class FakeRemoteHost: RemoteSessionHost {
    struct Run: Equatable {
        var handle: String
        var sessionID: String
        var attachment = 1
        var ended = false
        var leftRunning: RemoteLeftRunningReason?
        var resume: Bool
        var confirmed = false
        var dismissed = false
    }

    let hostName: String
    var runs: [Run] = []
    private var counter = 0

    var collectResult: RemoteLaunchOutcome = .ok(directory: "/home/u/project")
    var liveness: RemoteLiveness = .present
    var stopResult: RemoteStopResult = .stopped
    var master = true
    /// Holds a stop until released (a quit's hung query), by handle; a
    /// held stop that is cancelled throws, as one with no answer does.
    var stopGate: ((String) async -> Void)?
    var openError: Error?
    var openGate: (() async -> Void)?
    /// Holds an exit check until released.
    var exitGate: (() async -> Void)?
    var diagnosticsText: String?
    var decision = false
    private(set) var retired = false

    private(set) var opens: [(sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool, startNew: Bool)] = []
    private(set) var collects: [String] = []
    private(set) var stops: [(handle: String, fromAttachedTab: Bool)] = []
    private(set) var leftRunningCalls: [(handle: String, reason: RemoteLeftRunningReason)] = []
    private(set) var abandoned: [String] = []
    private(set) var unproven: [String] = []
    private(set) var kept: [String] = []
    private(set) var confirmations: [String] = []
    private(set) var discarded: [String] = []

    init(_ name: String) { hostName = name }

    func availability(_ agent: Agent) -> LaunchAvailability { agent == .codex ? .unavailable(reason: "1b") : .available }
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch { throw HostLaunchError.preparation("async only") }

    func live(_ sessionID: String) -> Int? { runs.lastIndex { $0.sessionID == sessionID && !$0.ended && !$0.dismissed } }

    func open(agent: Agent, sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool,
              startNew: Bool) async throws -> RemoteOpenResult {
        opens.append((sessionID, resume, directory, resumeAnyway, startNew))
        if let openGate { await openGate() }
        if let openError { throw openError }
        if let index = live(sessionID), !resumeAnyway, !startNew {
            runs[index].attachment += 1
            runs[index].leftRunning = nil
            return .plan(RemoteOpenPlan(handle: runs[index].handle, attachment: runs[index].attachment, creating: false,
                                        command: TerminalCommand(argv: ["ssh", "attach", runs[index].handle], cwd: "/Users/me"),
                                        displayArgv: ["claude", "--resume", sessionID],
                                        evidenceDirectory: "/home/u/evidence"))
        }
        if decision, resume, !startNew, !resumeAnyway { return .needsDecision }
        counter += 1
        let run = Run(handle: "h\(counter)", sessionID: sessionID, resume: resume && !startNew)
        runs.append(run)
        return .plan(RemoteOpenPlan(handle: run.handle, attachment: 1, creating: true,
                                    command: TerminalCommand(argv: ["ssh", "create", run.handle], cwd: "/Users/me"),
                                    displayArgv: ["claude", run.resume ? "--resume" : "--session-id", sessionID]))
    }

    func abandon(_ handle: String) async { abandoned.append(handle) }
    func collect(_ handle: String) async -> RemoteLaunchOutcome { collects.append(handle); return collectResult }
    func diagnostics(_ handle: String) async -> String? { diagnosticsText }
    func markCreationUnproven(_ handle: String) async { unproven.append(handle) }
    func confirmConversation(_ handle: String) async { confirmations.append(handle) }

    func discard(sessionID: String) async throws {
        discarded.append(sessionID)
        for index in runs.indices where runs[index].sessionID == sessionID { runs[index].dismissed = true }
    }

    func exitCheck(_ handle: String) async -> RemoteLiveness {
        if let exitGate { await exitGate() }
        if liveness == .absent, let index = runs.firstIndex(where: { $0.handle == handle }) { runs[index].ended = true }
        return liveness
    }

    func attachment(of handle: String) async -> Int? { runs.first { $0.handle == handle }?.attachment }

    func stop(_ handle: String, fromAttachedTab: Bool) async throws -> RemoteStopResult {
        stops.append((handle, fromAttachedTab))
        if let stopGate { await stopGate(handle) }
        if Task.isCancelled { throw CancellationError() }
        guard let index = runs.firstIndex(where: { $0.handle == handle }) else { return stopResult }
        switch stopResult {
        case .stopped: runs[index].ended = true
        case .leftRunning(let reason, _): runs[index].leftRunning = reason
        case .unrecorded: break
        }
        return stopResult
    }

    func leaveRunning(_ handle: String, reason: RemoteLeftRunningReason) async {
        leftRunningCalls.append((handle, reason))
        if let index = runs.firstIndex(where: { $0.handle == handle }), !runs[index].ended { runs[index].leftRunning = reason }
    }

    func hasLiveRun(sessionID: String) -> Bool { live(sessionID) != nil }
    func liveRunHandle(sessionID: String) async -> String? { live(sessionID).map { runs[$0].handle } }
    func hasLiveMaster() async -> Bool { master }
    func manualStopCommand(handle: String) -> String { "tmux -L temple kill-session -t temple-\(handle)" }
    var tracked: (sessions: [RemoteTrackedSession], checked: Bool) = ([], true)
    func trackedSessions() async -> (sessions: [RemoteTrackedSession], checked: Bool) { tracked }
    func keep(_ handle: String) async { kept.append(handle) }
    var unnoticed = 0
    var hostAnswers = true
    func contactLeftRunning() async -> Int? { hostAnswers ? unnoticed : nil }
    func noticeLeftRunning() async { unnoticed = 0 }
    var folder: RemoteFolderCheck = .missing
    var folderGate: (() async -> Void)?
    func checkFolder(_ path: String) async -> RemoteFolderCheck {
        if let folderGate { await folderGate() }
        return folder
    }
    func retire() { retired = true }
}

@MainActor
final class RemoteLifecycleTests: XCTestCase {
    let hostID = HostID(rawValue: "box")
    var remote: FakeRemoteHost!
    var factory: FakeTerminalSurfaceFactory!
    var model: OpenSessionsModel!
    var persistence: UserDefaultsTabPersistence!
    var rows: [String: Session] = [:]
    var recordedDirectories: [(String, HostID, String)] = []
    var notices: [String] = []

    override func setUp() async throws {
        remote = FakeRemoteHost("box")
        factory = FakeTerminalSurfaceFactory()
        persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        makeModel()
    }

    func makeModel(launcher: ((HostID) -> (any HostLauncher)?)? = nil) {
        let remote = self.remote!
        let host = hostID
        model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(gracefulTimeout: 0.3), registry: InMemoryProcessRegistry(),
            persistence: persistence,
            launcherForHost: launcher ?? { $0 == host ? remote : nil })
        model.earlyExitGraceSeconds = 0.5
        model.recordPollDelays = [0.01]
        model.settleDelaySeconds = 60
        model.sessionRow = { [weak self] in self?.rows[$0] }
        model.launchDirectoryHandler = { [weak self] id, host, directory in self?.recordedDirectories.append((id, host, directory)) }
        model.remoteNoticeHandler = { [weak self] _, message in self?.notices.append(message) }
    }

    private func settle(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func openRow(_ id: String = "s1", directory: String = "/home/u/project") async -> SessionTab {
        let row = Fixture.row(id, project: directory, host: hostID)
        rows[id] = row
        model.openSession(row)
        let tab = model.activeTab!
        await settle(tab.hasLiveProcess, "the tab connects")
        return tab
    }

    // MARK: Open

    func testANewSessionCreatesThenItsOKAppliesTheCanonicalFolderEverywhere() async throws {
        let tab = model.newSession(agent: .claude, project: Fixture.key("~/project", host: hostID))
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.first?.resume, false)
        XCTAssertEqual(remote.opens.first?.directory, "~/project")
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "h1"])
        XCTAssertEqual(tab.remote?.creating, true)
        XCTAssertEqual(tab.displayArgv, ["claude", "--session-id", tab.sessionID!])
        await settle(!self.recordedDirectories.isEmpty, "the pane's ok is collected")
        // One operation: the row, the tab, its project, recency, the next save.
        XCTAssertEqual(recordedDirectories.first?.2, "/home/u/project")
        XCTAssertEqual(tab.projectPath, "/home/u/project")
        XCTAssertEqual(model.activeProjectKey, Fixture.key("/home/u/project", host: hostID))
        XCTAssertEqual(model.projectKeysByRecency, [Fixture.key("/home/u/project", host: hostID)])
        XCTAssertEqual(persistence.load().first?.projectPath, "/home/u/project")
    }

    func testAnAttachClaimsNoFolder() async throws {
        remote.runs = [.init(handle: "old", sessionID: "s1", resume: false)]
        let tab = await openRow()
        XCTAssertEqual(tab.remote?.creating, false)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "old"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(remote.collects.isEmpty, "an attach runs no pane and produces no record")
        XCTAssertEqual(recordedDirectories.map(\.2), ["/home/u/evidence"], "only the creation's persisted evidence")
    }

    func testARefusedOpenSpawnsNothingAndSaysWhy() async throws {
        remote.openError = HostLaunchError.preparation("Temple couldn't record this session before starting it: disk full")
        let row = Fixture.row("s1", project: "/p", host: hostID)
        rows["s1"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        await settle(tab.launchPreparationError != nil)
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertEqual(tab.launchPreparationError, "Temple couldn't record this session before starting it: disk full")
    }

    func testARemovedHostIsNotSetUpAndIsNeverAsked() async throws {
        makeModel(launcher: { _ in nil })
        let row = Fixture.row("s1", project: "/p", host: hostID)
        rows["s1"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(tab.launchPreparationError, "Host box is not set up. Add it in Settings to open this session.")
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertTrue(remote.opens.isEmpty)
    }

    func testAClosedTabDuringTheOpenAbandonsTheCreation() async throws {
        let row = Fixture.row("s1", project: "/p", host: hostID)
        rows["s1"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        model.closeTab(tab.id)
        await settle(!self.remote.abandoned.isEmpty || !self.remote.opens.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(factory.created.isEmpty, "nothing spawns for a tab that went")
        XCTAssertEqual(remote.abandoned, ["h1"])
    }

    // MARK: Exit

    func testExitPresentKeepsTheTabDisconnectedAndOpeningAgainAttaches() async throws {
        let tab = await openRow()
        try await Task.sleep(for: .milliseconds(600))
        remote.liveness = .present
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .disconnected)
        XCTAssertTrue(model.tabs.contains { $0 === tab })
        // Open again: an attach, never a creation.
        model.openSession(rows["s1"]!)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.count, 2)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "h1"])
        XCTAssertEqual(remote.runs.count, 1)
    }

    func testExitUnknownOffersResumeAnywayWhichStartsANewRunAndKeepsTheOld() async throws {
        let tab = await openRow()
        try await Task.sleep(for: .milliseconds(600))
        remote.liveness = .unknown(reason: "no server running on /tmp/tmux-1000/temple")
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .unknown(reason: "no server running on /tmp/tmux-1000/temple"))
        XCTAssertEqual(model.resumeAnywayMessage(tab),
                       "Temple can't reach this session on box and can't tell whether it is still running. Resume anyway? "
                       + "If the original is still running, it keeps running; you can stop it from box with "
                       + "`tmux -L temple kill-session -t temple-h1`.")
        // Opening again is attach-only.
        model.reconnect(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "h1"])
        factory.created.last?.simulateExit(status: 1)
        await settle(tab.remote?.phase == .unknown(reason: "no server running on /tmp/tmux-1000/temple"))
        model.resumeAnyway(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.last?.resumeAnyway, true)
        XCTAssertEqual(remote.opens.last?.resume, true)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "h2"])
        XCTAssertFalse(remote.runs[0].ended, "the old run is kept, so Stop still reaches it")
    }

    func testAnAgentThatFinishedClosesItsTab() async throws {
        let tab = await openRow()
        try await Task.sleep(for: .milliseconds(600))
        remote.liveness = .absent
        factory.created.last?.simulateExit(status: 0)
        await settle(!self.model.tabs.contains { $0 === tab })
    }

    func testAnAttachThatFindsNothingResumesOnce() async throws {
        remote.runs = [.init(handle: "old", sessionID: "s1", resume: false)]
        let tab = await openRow()
        remote.liveness = .absent
        factory.created.last?.simulateExit(status: 1)
        await settle(self.factory.created.count == 2 && tab.hasLiveProcess, "a new run, resumed")
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "h1"])
        XCTAssertEqual(remote.opens.last?.resume, true)
        // The new run's own early end does not resume again.
        factory.created.last?.simulateExit(status: 1)
        await settle(tab.remote?.phase == .exitedEarly)
        XCTAssertEqual(factory.created.count, 2)
    }

    func testAPaneThatCouldNotEnterItsFolderShowsTheFailure() async throws {
        remote.collectResult = .failedCD(directory: "/gone")
        let tab = await openRow(directory: "/gone")
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .failedToStart(directory: "/gone"))
        XCTAssertEqual(tab.launchFailure?.message, "Temple couldn't enter the folder /gone on box.")
        XCTAssertTrue(recordedDirectories.isEmpty)
    }

    func testANothingCollectedCreationIsUnproven() async throws {
        remote.collectResult = .nothing
        let tab = await openRow()
        factory.created.last?.simulateExit(status: 1)
        await settle(tab.remote?.phase != .checking)
        XCTAssertEqual(remote.unproven, ["h1"])
    }

    func testAnExitCheckForAnOlderAttachmentIsDropped() async throws {
        let gate = Gate()
        let tab = await openRow()
        try await Task.sleep(for: .milliseconds(600))
        remote.exitGate = { await gate.wait() }
        remote.liveness = .absent
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .checking)
        // The user reopens meanwhile: the run gets a newer attachment.
        remote.runs[0].attachment += 1
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.tabs.contains { $0 === tab }, "a late absence for an older attachment closes nothing")
    }

    // MARK: Close

    func testClosingAnIdleTabStopsItNowFromTheTabAndTheTabGoes() async throws {
        let tab = await openRow()
        tab.activity = .idle
        let surface = try XCTUnwrap(factory.created.last)
        model.requestClose(tabID: tab.id)
        XCTAssertNil(model.pendingRemoteCloseTabID, "no prompt for an idle agent")
        XCTAssertTrue(surface.didTerminate, "Temple's own client goes first")
        XCTAssertFalse(model.tabs.contains { $0 === tab })
        await settle(self.remote.stops.count == 1)
        XCTAssertEqual(remote.stops.first?.fromAttachedTab, true)
        XCTAssertTrue(remote.runs[0].ended)
        XCTAssertTrue(notices.isEmpty)
    }

    func testAStopNotConfirmedLeavesItRunningWithOneNotice() async throws {
        remote.stopResult = .leftRunning(.hostDidNotAnswer, detail: "ssh: connect to host box: Operation timed out")
        let tab = await openRow()
        tab.activity = .idle
        model.closeTab(tab.id)
        await settle(!self.notices.isEmpty)
        XCTAssertEqual(notices, ["Left running: box didn't answer when you closed it. Stop it under Sessions on box."])
        remote.stopResult = .leftRunning(.anotherClientAttached, detail: nil)
        let other = await openRow("s2")
        other.activity = .idle
        model.closeTab(other.id)
        await settle(self.notices.count == 2)
        XCTAssertEqual(notices.last, "Left running: another terminal is attached to it. Stop it under Sessions on box.")
    }

    func testClosingAWorkingTabAsksDetachOrStop() async throws {
        let tab = await openRow()
        tab.activity = .running
        model.requestClose(tabID: tab.id)
        XCTAssertEqual(model.pendingRemoteCloseTabID, tab.id)
        XCTAssertNil(model.pendingCloseTabID)
        model.cancelRemoteClose()
        XCTAssertTrue(model.tabs.contains { $0 === tab })
        // Detach: the client goes, the agent keeps working, nothing is stopped.
        model.requestClose(tabID: tab.id)
        model.confirmRemoteDetach()
        XCTAssertFalse(model.tabs.contains { $0 === tab })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(remote.stops.isEmpty)
        XCTAssertFalse(remote.runs[0].ended)
    }

    func testStopFromTheWorkingPromptKeepsTheTabUntilTheOutcome() async throws {
        let gate = Gate()
        remote.stopGate = { _ in await gate.wait() }
        let tab = await openRow()
        tab.activity = .running
        model.requestClose(tabID: tab.id)
        model.confirmRemoteStop()
        XCTAssertEqual(tab.remote?.phase, .stopping)
        XCTAssertTrue(model.tabs.contains { $0 === tab })
        await gate.open()
        await settle(!self.model.tabs.contains { $0 === tab })
        // Unconfirmed: the tab is kept with the uncertainty line.
        let second = await openRow("s2")
        second.activity = .running
        remote.stopGate = nil
        remote.stopResult = .leftRunning(.stopNotAcknowledged, detail: "Didn't answer within 10 seconds.")
        model.requestClose(tabID: second.id)
        model.confirmRemoteStop()
        await settle({ if case .stopFailed = second.remote?.phase { return true }; return false }())
        XCTAssertEqual(second.remote?.phase, .stopFailed(
            "Temple couldn't stop Claude Code on box: Didn't answer within 10 seconds. It may still be running; see Sessions on box."))
    }

    func testClosingADisconnectedTabStopsWithNoTempleClientAttached() async throws {
        let tab = await openRow()
        try await Task.sleep(for: .milliseconds(600))
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .disconnected)
        model.closeTab(tab.id)
        XCTAssertFalse(model.tabs.contains { $0 === tab })
        await settle(self.remote.stops.count == 1)
        XCTAssertEqual(remote.stops.first?.fromAttachedTab, false)
    }

    func testStopOnHostFromARowWithoutATab() async throws {
        remote.runs = [.init(handle: "h9", sessionID: "s9", resume: true)]
        rows["s9"] = Fixture.row("s9", project: "/p", host: hostID)
        XCTAssertTrue(model.hasRemoteRun(sessionID: "s9", host: hostID))
        model.stopRemoteSession(sessionID: "s9", host: hostID)
        await settle(self.remote.stops.count == 1)
        XCTAssertEqual(remote.stops.first?.fromAttachedTab, false)
        await settle(!self.model.hasRemoteRun(sessionID: "s9", host: hostID))
    }

    // MARK: Ownership

    private func drain(timeout: TimeInterval = 0.5) async -> TimeInterval {
        let plan = model.quitDrainPlan()
        let done = expectation(description: "drained")
        let started = Date()
        SessionRuntimeController(gracefulTimeout: timeout).drainAll(graceful: plan.graceful, detach: plan.detach,
                                                                    remote: model.remoteOperations) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return Date().timeIntervalSince(started)
    }

    /// A close's stop is owned past the tab: the quit waits for it inside
    /// its window and, at the deadline, records it left running.
    func testAClosesStopInFlightIsOwnedThroughTheQuit() async throws {
        let gate = Gate()
        remote.stopGate = { _ in await gate.wait() }
        let tab = await openRow()
        tab.activity = .idle
        model.closeTab(tab.id)
        XCTAssertFalse(model.tabs.contains { $0 === tab })
        await settle(self.remote.stops.count == 1)
        XCTAssertEqual(model.remoteOperations.stopsOutstanding, 1)
        model.prepareForQuit()
        let elapsed = await drain()
        XCTAssertLessThan(elapsed, 1.5)
        await settle(self.remote.leftRunningCalls.count == 1)
        XCTAssertEqual(remote.leftRunningCalls.first?.reason, .quitDeadline)
        let written = await model.remoteOperations.waitForAll(until: Date().addingTimeInterval(1))
        XCTAssertFalse(written, "the hung stop is still owned (its answer, if it came, would be written)")
        await gate.open()
        let finished = await model.remoteOperations.waitForAll(until: Date().addingTimeInterval(2))
        XCTAssertTrue(finished)
    }

    func testTheQuitDrainDetachesWorkingStopsIdleAndBoundsHungStops() async throws {
        let working = await openRow("w")
        working.activity = .running
        let idle = await openRow("i")
        idle.activity = .idle
        let hung = await openRow("h")
        hung.activity = .idle
        let workingSurface = try XCTUnwrap(working.surface as? FakeTerminalSurface)
        let gate = Gate()
        remote.stopGate = { handle in
            if handle == "h3" { await gate.wait() }
        }
        model.prepareForQuit()
        let elapsed = await drain()
        XCTAssertTrue(workingSurface.didTerminate, "a working agent's client goes at once, with no exit input")
        XCTAssertFalse(workingSurface.didRequestGracefulExit)
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(remote.stops.map(\.handle).sorted(), ["h2", "h3"])
        XCTAssertTrue(remote.stops.allSatisfy(\.fromAttachedTab))
        await settle(self.remote.leftRunningCalls.count == 1)
        XCTAssertEqual(remote.leftRunningCalls.map(\.reason), [.quitDeadline])
        XCTAssertEqual(remote.leftRunningCalls.first?.handle, "h3")
        XCTAssertTrue(remote.runs.first { $0.handle == "h2" }!.ended)
        XCTAssertTrue(model.tabs.count == 3, "the tab set is frozen for the next launch")
        await gate.open()
    }

    /// Planned from the run and the tab, not only from a live client: an
    /// agent whose client had already ended while it was idle is stopped
    /// too (with no Temple client attached); one last seen working is not.
    func testAQuitStopsADisconnectedIdleAgentButNotADisconnectedWorkingOne() async throws {
        let idle = await openRow("i")
        idle.activity = .idle
        let working = await openRow("w")
        working.activity = .running
        try await Task.sleep(for: .milliseconds(600))
        idle.surface.map { ($0 as? FakeTerminalSurface)?.simulateExit(status: 0) }
        working.surface.map { ($0 as? FakeTerminalSurface)?.simulateExit(status: 0) }
        await settle(idle.remote?.phase == .disconnected && working.remote?.phase == .disconnected)
        model.prepareForQuit()
        _ = await drain()
        XCTAssertEqual(remote.stops.map(\.handle), [idle.remote!.handle!])
        XCTAssertEqual(remote.stops.first?.fromAttachedTab, false)
    }

    func testAQuitDoesNotAskAHostWithoutALiveMaster() async throws {
        let idle = await openRow("i")
        idle.activity = .idle
        remote.master = false
        model.prepareForQuit()
        _ = await drain()
        await settle(!self.remote.leftRunningCalls.isEmpty)
        XCTAssertTrue(remote.stops.isEmpty)
        XCTAssertEqual(remote.leftRunningCalls.map(\.reason), [.hostDidNotAnswer])
    }

    func testAQuitWithNothingStillCompletesAsynchronously() {
        var completed = false
        SessionRuntimeController(gracefulTimeout: 0.2).drainAll(graceful: [], detach: [], remote: RemoteOperations()) {
            completed = true
        }
        XCTAssertFalse(completed, "never synchronously")
    }

    /// A host removed or edited: its operations are cancelled (a stop is
    /// recorded left running), its open is not spawned even when its answer
    /// comes, and its connected clients are detached.
    func testRetiringAHostCancelsItsWorkAndDetachesItsClients() async throws {
        let connected = await openRow("c")
        let surface = try XCTUnwrap(connected.surface as? FakeTerminalSurface)
        let openGate = Gate()
        remote.openGate = { await openGate.wait() }
        let row = Fixture.row("o", project: "/p", host: hostID)
        rows["o"] = row
        model.openSession(row)
        let opening = try XCTUnwrap(model.activeTab)
        let stopGate = Gate()
        remote.stopGate = { _ in await stopGate.wait() }
        model.stopRemoteSession(sessionID: "c", host: hostID)
        await settle(self.remote.stops.count == 1)
        model.retireRemoteHost(hostID)
        XCTAssertTrue(remote.retired)
        XCTAssertTrue(surface.didTerminate)
        await settle(self.remote.leftRunningCalls.count == 1)
        XCTAssertEqual(remote.leftRunningCalls.first?.reason, .stopNotAcknowledged)
        await openGate.open()
        await stopGate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(opening.surface, "an open answered for a retired host spawns nothing")
        XCTAssertEqual(factory.created.count, 1)
    }

    func testAFinalCollectionAfterACloseChangesNothing() async throws {
        let gate = Gate()
        remote.exitGate = { await gate.wait() }
        remote.collectResult = .nothing
        let tab = await openRow()
        try await Task.sleep(for: .milliseconds(100))
        remote.collectResult = .ok(directory: "/home/u/late")
        factory.created.last?.simulateExit(status: 0)
        model.closeTab(tab.id)
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(recordedDirectories.contains { $0.2 == "/home/u/late" })
    }

    // MARK: Unconfirmed conversations, diagnostics

    func testAnUnconfirmedConversationOffersStartANewSessionOrDiscard() async throws {
        remote.decision = true
        var discardedRows: [String] = []
        model.discardHandler = { id, _ in discardedRows.append(id) }
        let row = Fixture.row("u", project: "/p", host: hostID)
        rows["u"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        await settle(tab.remote?.phase == .needsDecision)
        XCTAssertTrue(factory.created.isEmpty, "never resumed blindly")
        model.startNewRemoteSession(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.last?.startNew, true)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "h1"])
        // Discard instead, on another.
        let other = Fixture.row("v", project: "/p", host: hostID)
        rows["v"] = other
        model.openSession(other)
        let second = try XCTUnwrap(model.activeTab)
        await settle(second.remote?.phase == .needsDecision)
        model.discardRemoteSession(second)
        XCTAssertFalse(model.tabs.contains { $0 === second })
        await settle(discardedRows == ["v"])
        XCTAssertEqual(remote.discarded, ["v"])
    }

    func testTheFirstInputConfirmsTheConversation() async throws {
        let tab = await openRow()
        let surface = try XCTUnwrap(tab.surface as? FakeTerminalSurface)
        model.surfaceDidSubmitInput(surface)
        model.surfaceDidSubmitInput(surface)
        await settle(self.remote.confirmations == ["h1"])
        XCTAssertEqual(remote.confirmations, ["h1"], "once")
    }

    func testAnAgentThatFailsAtOnceShowsWhatItPrinted() async throws {
        remote.liveness = .absent
        remote.diagnosticsText = "\u{1b}[2J\u{1b}[1;31mError:\u{1b}[0m No conversation found with session ID: s1\r\n\u{1b}]0;title\u{07}"
        let tab = await openRow()
        factory.created.last?.simulateExit(status: 1)
        await settle(!(tab.remote?.diagnostics ?? []).isEmpty)
        XCTAssertEqual(tab.remote?.phase, .exitedEarly)
        XCTAssertEqual(tab.remote?.diagnostics, ["Error: No conversation found with session ID: s1"])
    }

    /// The failing agent was the server's only session: the server went too,
    /// the check can't tell (Unknown), and what it printed is still shown.
    func testAFailureThatTookTheServerStillShowsWhatItPrinted() async throws {
        remote.liveness = .unknown(reason: "no server running on /tmp/tmux-1000/temple")
        remote.diagnosticsText = "No conversation found with session ID: s1\r\n"
        let tab = await openRow()
        factory.created.last?.simulateExit(status: 1)
        await settle(!(tab.remote?.diagnostics ?? []).isEmpty)
        XCTAssertEqual(tab.remote?.phase, .unknown(reason: "no server running on /tmp/tmux-1000/temple"))
        XCTAssertEqual(tab.remote?.diagnostics, ["No conversation found with session ID: s1"])
    }

    func testAnAttachReplaysThePersistedEvidence() async throws {
        remote.runs = [.init(handle: "old", sessionID: "s1", resume: false)]
        _ = await openRow()
        await settle(self.recordedDirectories.contains { $0.2 == "/home/u/evidence" })
    }

    func testWorkingCountsAreLocalOnlyAndNameTheHosts() async throws {
        let tab = await openRow()
        tab.activity = .running
        XCTAssertEqual(model.workingTabs.count, 1)
        XCTAssertEqual(model.localWorkingTabs.count, 0)
        XCTAssertEqual(model.remoteWorkingHosts, ["box"])
        let prompt = TempleAppDelegate.quitPrompt(workingCount: 1, remoteHosts: ["box", "jet"])
        XCTAssertEqual(prompt.title, "An agent is still working.")
        XCTAssertTrue(prompt.message.hasSuffix("Sessions working on box and jet keep running; Temple will reconnect to them."))
        XCTAssertFalse(TempleAppDelegate.quitPrompt(workingCount: 2, remoteHosts: []).message.contains("keep running"))
    }

    // MARK: Restore

    func testARemoteTabRestoresUnderItsRowsHostAndAttachesOnActivation() async throws {
        remote.runs = [.init(handle: "kept", sessionID: "s1", resume: false)]
        persistence.save([PersistedTab(sessionID: "s1", agent: .claude, projectPath: "/home/u/project", title: "T", isActive: false)])
        rows["s1"] = Fixture.row("s1", project: "/home/u/project", host: hostID)
        model.restore()
        let tab = try XCTUnwrap(model.tabs.first)
        XCTAssertEqual(tab.host, hostID)
        XCTAssertFalse(tab.hasSurface, "an inert chip")
        model.activate(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "kept"])
        // A stopped session's chip starts a new run with resume.
        remote.runs[0].ended = true
        model.closeTab(tab.id)
        persistence.save([PersistedTab(sessionID: "s1", agent: .claude, projectPath: "/home/u/project", title: "T", isActive: true)])
        makeModel()
        model.restore()
        await settle(self.model.activeTab?.hasLiveProcess == true)
        XCTAssertEqual(remote.opens.last?.resume, true)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv.prefix(2), ["ssh", "create"])
    }

    func testNewCodexSessionsOnAHostWaitButAnIDResumes() async throws {
        let tab = model.newSession(agent: .codex, project: Fixture.key("/p", host: hostID))
        XCTAssertEqual(tab.launchPreparationError, "Temple can't start new Codex sessions on box yet.")
        XCTAssertTrue(factory.created.isEmpty)
        let row = Fixture.row("c1", agent: .codex, project: "/p", host: hostID)
        rows["c1"] = row
        model.openSession(row)
        await settle(self.model.activeTab?.hasLiveProcess == true)
        XCTAssertEqual(remote.opens.last?.sessionID, "c1")
    }
}

/// A one-shot gate a test opens.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
