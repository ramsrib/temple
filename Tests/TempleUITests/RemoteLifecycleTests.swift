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
    var decisionChecked = true
    var diagnosticsGate: (() async -> Void)?
    var collectGate: (() async -> Void)?
    private(set) var retired = false

    private(set) var opens: [(sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool, startNew: Bool,
                              resumeUnconfirmed: Bool)] = []
    private(set) var collects: [String] = []
    private(set) var stops: [(handle: String, fromAttachedTab: Bool)] = []
    private(set) var leftRunningCalls: [(handle: String, reason: RemoteLeftRunningReason)] = []
    private(set) var abandoned: [String] = []
    private(set) var unproven: [String] = []
    private(set) var kept: [String] = []
    private(set) var discarded: [String] = []

    init(_ name: String) { hostName = name }

    func availability(_ agent: Agent) -> LaunchAvailability { .available }
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch { throw HostLaunchError.preparation("async only") }

    func live(_ sessionID: String) -> Int? { runs.lastIndex { $0.sessionID == sessionID && !$0.ended && !$0.dismissed } }

    func open(agent: Agent, sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool,
              startNew: Bool, resumeUnconfirmed: Bool) async throws -> RemoteOpenResult {
        opens.append((sessionID, resume, directory, resumeAnyway, startNew, resumeUnconfirmed))
        if let openGate { await openGate() }
        if let openError { throw openError }
        if let index = live(sessionID), !resumeAnyway, !startNew {
            runs[index].attachment += 1
            runs[index].leftRunning = nil
            return .plan(RemoteOpenPlan(handle: runs[index].handle, attachment: runs[index].attachment, creating: false,
                                        command: TerminalCommand(argv: ["ssh", "attach", runs[index].handle], cwd: "/Users/me"),
                                        displayArgv: ["claude", "--resume", sessionID],
                                        evidenceDirectory: "/home/u/evidence",
                                        stage: stageAfterSpawn ? "stage-\(runs[index].handle)" : nil))
        }
        if decision, resume, !startNew, !resumeAnyway, !resumeUnconfirmed { return .needsDecision(checked: decisionChecked) }
        counter += 1
        let run = Run(handle: "h\(counter)", sessionID: sessionID, resume: resume && !startNew)
        runs.append(run)
        return .plan(RemoteOpenPlan(handle: run.handle, attachment: 1, creating: true,
                                    command: TerminalCommand(argv: ["ssh", "create", run.handle], cwd: "/Users/me"),
                                    displayArgv: ["claude", run.resume ? "--resume" : "--session-id", sessionID],
                                    stage: stageAfterSpawn ? "stage-\(run.handle)" : nil))
    }

    func abandon(_ handle: String) async { abandoned.append(handle) }
    func collect(_ handle: String) async -> RemoteLaunchOutcome {
        collects.append(handle)
        if let collectGate { await collectGate() }
        return collectResult
    }
    func diagnostics(_ handle: String) async -> String? {
        if let diagnosticsGate { await diagnosticsGate() }
        return diagnosticsText
    }
    /// What `markCreationUnproven` answers: nil, or why the creation was
    /// recorded failed instead (its launch never reached the host).
    var unsentReason: String?
    func markCreationUnproven(_ handle: String) async -> String? {
        unproven.append(handle)
        return unsentReason
    }

    /// Staging after the spawn: plans carry a stage when `stageAfterSpawn`.
    var stageAfterSpawn = false
    var stageResult: RemoteStageResult = .staged
    var stageGate: (() async -> Void)?
    private(set) var stages: [String] = []
    func stage(_ name: String) async -> RemoteStageResult {
        stages.append(name)
        if let stageGate { await stageGate() }
        // An answer that had already arrived: the gate decides what shows.
        return stageResult
    }

    var discardGate: (() async -> Void)?
    var discardError: Error?
    func discard(sessionID: String) async throws {
        discarded.append(sessionID)
        if let discardGate { await discardGate() }
        if let discardError { throw discardError }
        for index in runs.indices where runs[index].sessionID == sessionID { runs[index].dismissed = true }
    }

    func exitCheck(_ handle: String) async -> RemoteLiveness {
        if let exitGate { await exitGate() }
        if liveness == .absent, let index = runs.firstIndex(where: { $0.handle == handle }) { runs[index].ended = true }
        if liveness == .absent, let index = pending.firstIndex(where: { $0.handle == handle }) { pending[index].ended = true }
        return liveness
    }

    func attachment(of handle: String) async -> Int? {
        runs.first { $0.handle == handle }?.attachment ?? pending.first { $0.handle == handle }?.attachment
    }

    func stop(_ handle: String, fromAttachedTab: Bool) async throws -> RemoteStopResult {
        stops.append((handle, fromAttachedTab))
        if let stopGate { await stopGate(handle) }
        // An answer that arrives after a cancellation is still an answer
        // (the real stop writes it); the caller's gate decides what shows.
        if stopResult == .stopped, let index = pending.firstIndex(where: { $0.handle == handle }) { pending[index].ended = true }
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
    var trackedGate: (() async -> Void)?
    func trackedSessions() async -> (sessions: [RemoteTrackedSession], checked: Bool) {
        if let trackedGate { await trackedGate() }
        return tracked
    }
    func keep(_ handle: String) async { kept.append(handle) }
    var unnoticed = 0
    var hostAnswers = true
    var contactGate: (() async -> Void)?
    func contactLeftRunning() async -> Int? {
        if let contactGate { await contactGate() }
        return hostAnswers ? unnoticed : nil
    }
    func noticeLeftRunning() async { unnoticed = 0 }
    var folder: RemoteFolderCheck = .missing
    var folderGate: (() async -> Void)?
    func checkFolder(_ path: String) async -> RemoteFolderCheck {
        if let folderGate { await folderGate() }
        return folder
    }
    func retire() { retired = true }

    // MARK: Codex identity

    /// A pending Codex run as the fake keeps it.
    struct Pending: Equatable {
        var handle: String
        var directory: String
        var sessionID: String?
        var attachment = 1
        var ended = false
        var dismissed = false
        var tabClosed = false
        var typed = false
        var claimed = false
        var joined = false
    }
    var pending: [Pending] = []
    private var pendingCounter = 0
    var pendingOpenGate: (() async -> Void)?
    private(set) var pendingOpens: [(handle: String?, directory: String)] = []
    func openPending(handle: String?, directory: String) async throws -> RemotePendingOpenResult {
        pendingOpens.append((handle, directory))
        if let pendingOpenGate { await pendingOpenGate() }
        if let openError { throw openError }
        guard let handle else {
            pendingCounter += 1
            let run = Pending(handle: "p\(pendingCounter)", directory: directory)
            pending.append(run)
            return .plan(RemoteOpenPlan(handle: run.handle, attachment: 1, creating: true,
                                        command: TerminalCommand(argv: ["ssh", "create", run.handle], cwd: "/Users/me"),
                                        displayArgv: ["codex"]))
        }
        guard let index = pending.firstIndex(where: { $0.handle == handle && !$0.dismissed }) else {
            throw HostLaunchError.preparation("Temple no longer tracks this session on \(hostName).")
        }
        if let id = pending[index].sessionID { return .identified(id, directory: pending[index].directory) }
        if pending[index].ended { return .ended }
        pending[index].attachment += 1
        pending[index].tabClosed = false
        return .plan(RemoteOpenPlan(handle: handle, attachment: pending[index].attachment, creating: false,
                                    command: TerminalCommand(argv: ["ssh", "attach", handle], cwd: "/Users/me"),
                                    displayArgv: ["codex"], evidenceDirectory: "/home/u/evidence"))
    }

    /// What the next identity checks answer (then `identityResult`).
    var identityAnswers: [RemoteIdentity] = []
    var identityResult: RemoteIdentity = .inconclusive("no session file is open right now", lasting: false, ended: false)
    var identityGate: (() async -> Void)?
    private(set) var identifies: [String] = []
    func identify(_ handle: String) async -> RemoteIdentity {
        identifies.append(handle)
        if let identityGate { await identityGate() }
        let answer = identityAnswers.isEmpty ? identityResult : identityAnswers.removeFirst()
        claim(answer, handle)
        return answer
    }

    private func claim(_ answer: RemoteIdentity, _ handle: String) {
        if case .adopted(let id, _) = answer, let index = pending.firstIndex(where: { $0.handle == handle }) {
            pending[index].sessionID = id
            pending[index].claimed = true
        }
    }

    /// The run store, as a hand-over obligation holds it: kept (and
    /// written) whatever becomes of this host's registry entry. Fails as
    /// many times as `ledgerFailures` says.
    var ledgerFailures = 0
    var ledgerGate: (() async -> Void)?
    private(set) var ledgerWrites: [String] = []
    final class Ledger: RemoteRunLedger {
        weak var host: FakeRemoteHost?
        init(_ host: FakeRemoteHost) { self.host = host }
        func markTabClosed(_ handle: String) async throws {
            guard let host else { return }
            host.ledgerWrites.append(handle)
            if let gate = host.ledgerGate { await gate() }
            if host.ledgerFailures > 0 {
                host.ledgerFailures -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            host.closedPending.append(handle)
            if let index = host.pending.firstIndex(where: { $0.handle == handle }) { host.pending[index].tabClosed = true }
        }
    }
    func runLedger() -> RemoteRunLedger? { Ledger(self) }

    private(set) var inputs: [String] = []
    /// How many input writes fail before one is written.
    var inputFailures = 0
    func recordInput(_ handle: String) async throws {
        inputs.append(handle)
        if inputFailures > 0 {
            inputFailures -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        if let index = pending.firstIndex(where: { $0.handle == handle }) { pending[index].typed = true }
    }

    var suggestionsResult: RemoteSuggestions = .candidates([])
    var suggestionsGate: (() async -> Void)?
    private(set) var suggestionLookups: [String] = []
    func suggestions(_ handle: String) async -> RemoteSuggestions {
        suggestionLookups.append(handle)
        if let suggestionsGate { await suggestionsGate() }
        return suggestionsResult
    }

    var confirmResult: RemoteIdentity?
    var confirmGate: (() async -> Void)?
    private(set) var confirms: [(handle: String, sessionID: String)] = []
    func confirm(_ handle: String, suggestion: RemoteSuggestion) async -> RemoteIdentity {
        confirms.append((handle, suggestion.sessionID))
        if let confirmGate { await confirmGate() }
        let answer = confirmResult ?? .adopted(suggestion.sessionID, directory: suggestion.directory)
        claim(answer, handle)
        return answer
    }

    var declineError: Error?
    var declineGate: (() async -> Void)?
    private(set) var declines: [(handle: String, path: String)] = []
    func decline(_ handle: String, rolloutPath: String) async throws {
        declines.append((handle, rolloutPath))
        if let declineGate { await declineGate() }
        if let declineError { throw declineError }
    }

    private(set) var released: [(handle: String, sessionID: String)] = []
    func releaseClaim(_ handle: String, sessionID: String) async throws {
        released.append((handle, sessionID))
        if let index = pending.firstIndex(where: { $0.handle == handle }) {
            pending[index].sessionID = nil
            pending[index].claimed = false
        }
        unjoined.removeAll { $0.handle == handle }
    }

    private(set) var joinedMarks: [String] = []
    func markJoined(_ handle: String) async throws {
        joinedMarks.append(handle)
        if let index = pending.firstIndex(where: { $0.handle == handle }) { pending[index].joined = true }
    }

    var unjoined: [(handle: String, sessionID: String, directory: String?)] = []
    func unjoinedClaims() async -> [(handle: String, sessionID: String, directory: String?)] { unjoined }

    var pendingRunsGate: (() async -> Void)?
    func pendingRuns() async -> [RemotePendingRun] {
        if let pendingRunsGate { await pendingRunsGate() }
        return pending.filter { ($0.sessionID == nil || $0.claimed) && !$0.dismissed && !$0.tabClosed }
            .map { RemotePendingRun(handle: $0.handle, directory: $0.directory, ended: $0.ended,
                                    sessionID: $0.claimed ? $0.sessionID : nil, typed: $0.typed, joined: $0.joined) }
    }

    fileprivate(set) var closedPending: [String] = []
    var closePendingError: Error?
    func closePendingTab(_ handle: String) async throws {
        closedPending.append(handle)
        if let closePendingError { throw closePendingError }
        if let index = pending.firstIndex(where: { $0.handle == handle }) { pending[index].tabClosed = true }
    }

    var dismissRunError: Error?
    var dismissRunGate: (() async -> Void)?
    private(set) var dismissedRuns: [String] = []
    func dismissRun(_ handle: String) async throws {
        dismissedRuns.append(handle)
        if let dismissRunGate { await dismissRunGate() }
        if let dismissRunError { throw dismissRunError }
        if let index = pending.firstIndex(where: { $0.handle == handle }) { pending[index].dismissed = true }
    }
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
        model.remoteTabs.recordPollDelays = [0.01]
        model.settleDelaySeconds = 60
        model.sessionRow = { [weak self] in self?.rows[$0] }
        model.launchDirectoryHandler = { [weak self] id, host, directory in self?.recordedDirectories.append((id, host, directory)) }
        model.remoteTabs.noticeHandler = { [weak self] _, message in self?.notices.append(message) }
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
        // The confirmation is short; the command that stops the original
        // stands apart in its sheet.
        XCTAssertEqual(RemoteCopy.resumeAnyway("box"),
                       "Temple can't reach this session on box and can't tell whether it is still running. "
                       + "If it is, it keeps running.")
        XCTAssertEqual(model.remoteTabs.stopCommand(tab), "tmux -L temple kill-session -t temple-h1")
        // Opening again is attach-only.
        model.remoteTabs.reconnect(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "h1"])
        factory.created.last?.simulateExit(status: 1)
        await settle(tab.remote?.phase == .unknown(reason: "no server running on /tmp/tmux-1000/temple"))
        model.remoteTabs.resumeAnyway(tab)
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

    /// B2: ⌘W closes a running tab as at rest early only on positive
    /// evidence that its agent has done nothing this spawn: nothing typed
    /// since it spawned, no title bringing it back from rest, and its title
    /// quiet (a reopen whose resume went quiet, a trust screen). Anything
    /// after a Return waits for the settle timer, then asks: an answered
    /// prompt, a long tool call with an unrelated retitle, an agent that
    /// never retitles; so does a title still moving. Quit is unchanged: a
    /// running tab is detached there, never stopped.
    func testCloseIsAtRestEarlyOnlyWhenNothingWasDoneSinceTheSpawn() async throws {
        model.titleQuietWindow = 0.15
        func quiet() async throws { try await Task.sleep(for: .milliseconds(250)) }
        func asks(_ tab: SessionTab, _ message: String, line: UInt = #line) {
            model.requestClose(tabID: tab.id)
            XCTAssertEqual(model.pendingRemoteCloseTabID, tab.id, message, line: line)
            model.remoteTabs.cancelClose()
            XCTAssertTrue(model.tabs.contains { $0 === tab }, line: line)
        }
        // Reopened, its resume booting, then quiet: at rest, stopped.
        let resumed = await openRow("s1")
        XCTAssertEqual(resumed.activity, .running, "a spawn boots into running")
        let surface = try XCTUnwrap(factory.created.last)
        surface.simulateTitle("⠙ project")
        surface.simulateTitle("project")
        try await quiet()
        model.requestClose(tabID: resumed.id)
        XCTAssertNil(model.pendingRemoteCloseTabID, "a resumed agent that did nothing is at rest")
        XCTAssertFalse(model.tabs.contains { $0 === resumed })
        await settle(self.remote.stops.count == 1)

        // A trust screen: no title, nothing typed, quiet.
        let trust = await openRow("s2")
        try await quiet()
        model.requestClose(tabID: trust.id)
        XCTAssertNil(model.pendingRemoteCloseTabID)

        // An answered prompt: asks until the timer has settled it.
        let answered = await openRow("s3")
        let answeredSurface = try XCTUnwrap(factory.created.last)
        answeredSurface.simulateSubmitInput()
        answeredSurface.simulateTitle("⠋ project")
        answeredSurface.simulateTitle("Reply ok | project")
        try await quiet()
        asks(answered, "after a Return, a quiet title is no evidence")

        // A long tool call: an unrelated retitle, then a held title.
        let tool = await openRow("s4")
        let toolSurface = try XCTUnwrap(factory.created.last)
        toolSurface.simulateSubmitInput()
        toolSurface.simulateTitle("running cargo test")
        try await quiet()
        asks(tool, "a long tool call is working")

        // An agent that never retitles.
        let silent = await openRow("s5")
        try XCTUnwrap(factory.created.last).simulateSubmitInput()
        try await quiet()
        asks(silent, "a Return with no title since is working")

        // Woke itself from rest (a title after a bell), then held its title.
        model.ringGraceSeconds = -1
        let woke = await openRow("s6")
        let wokeSurface = try XCTUnwrap(factory.created.last)
        wokeSurface.simulateBell()
        XCTAssertEqual(woke.activity, .idle)
        wokeSurface.simulateTitle("✳ Working")
        XCTAssertEqual(woke.activity, .running)
        try await quiet()
        asks(woke, "work it took up on its own is work")

        // A title still moving, nothing typed: working.
        let busy = await openRow("s7")
        try XCTUnwrap(factory.created.last).simulateTitle("⠋ project")
        asks(busy, "a moving title is working")

        // Quit keeps the timer's reading: the answered, quiet tab is
        // detached (its surface returned), not stopped.
        let stopsBefore = remote.stops.count
        XCTAssertNotNil(model.remoteTabs.quitPlan(for: answered, state: try XCTUnwrap(answered.remote)))
        XCTAssertNotNil(model.remoteTabs.quitPlan(for: tool, state: try XCTUnwrap(tool.remote)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(remote.stops.count, stopsBefore, "quit stops nothing that ran this spawn")
    }

    func testClosingAWorkingTabAsksDetachOrStop() async throws {
        let tab = await openRow()
        tab.activity = .running
        model.requestClose(tabID: tab.id)
        XCTAssertEqual(model.pendingRemoteCloseTabID, tab.id)
        XCTAssertNil(model.pendingCloseTabID)
        model.remoteTabs.cancelClose()
        XCTAssertTrue(model.tabs.contains { $0 === tab })
        // Detach: the client goes, the agent keeps working, nothing is stopped.
        model.requestClose(tabID: tab.id)
        model.remoteTabs.confirmDetach()
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
        model.remoteTabs.confirmStop()
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
        model.remoteTabs.confirmStop()
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
        XCTAssertTrue(model.remoteTabs.hasRun(sessionID: "s9", host: hostID))
        model.remoteTabs.stopSession(sessionID: "s9", host: hostID)
        await settle(self.remote.stops.count == 1)
        XCTAssertEqual(remote.stops.first?.fromAttachedTab, false)
        await settle(!self.model.remoteTabs.hasRun(sessionID: "s9", host: hostID))
    }

    // MARK: Ownership

    private func drain(timeout: TimeInterval = 0.5) async -> TimeInterval {
        let plan = model.quitDrainPlan()
        let done = expectation(description: "drained")
        let started = Date()
        SessionRuntimeController(gracefulTimeout: timeout).drainAll(graceful: plan.graceful, detach: plan.detach,
                                                                    remote: model.remoteTabs.operations) { done.fulfill() }
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
        XCTAssertEqual(model.remoteTabs.operations.stopsOutstanding, 1)
        model.prepareForQuit()
        let elapsed = await drain()
        XCTAssertLessThan(elapsed, 1.5)
        await settle(self.remote.leftRunningCalls.count == 1)
        XCTAssertEqual(remote.leftRunningCalls.first?.reason, .quitDeadline)
        let written = await model.remoteTabs.operations.waitForAll(until: Date().addingTimeInterval(1))
        XCTAssertFalse(written, "the hung stop is still owned (its answer, if it came, would be written)")
        await gate.open()
        let finished = await model.remoteTabs.operations.waitForAll(until: Date().addingTimeInterval(2))
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
        model.remoteTabs.stopSession(sessionID: "c", host: hostID)
        await settle(self.remote.stops.count == 1)
        model.remoteTabs.retireHost(hostID)
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

    // MARK: Staging after the spawn (first contact)

    /// The launch is staged after the tab connects; a refusal ends the
    /// client at once, and the exit says why (the creation was recorded
    /// failed by the host side, so the collection says so).
    func testALaunchThatCouldNotBeStagedEndsItsClientAndSaysWhy() async throws {
        remote.stageAfterSpawn = true
        remote.stageResult = .failed("~/.temple/launch isn't a private folder of this account's")
        // What the host side's collection says once it recorded the failure.
        remote.collectResult = .failedLaunch("the launch couldn't be prepared: ~/.temple/launch isn't a private folder of this account's")
        let row = Fixture.row("s1", project: "/home/u/project", host: hostID)
        rows["s1"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        await settle(factory.created.last?.didTerminate == true, "the client ends rather than wait out its own deadline")
        XCTAssertEqual(remote.stages, ["stage-h1"])
        await settle(tab.remote?.phase == .failedToStart(directory: tab.projectPath))
        XCTAssertTrue(tab.launchFailure?.message.hasPrefix("Temple couldn't start this session on box:") == true,
                      tab.launchFailure?.message ?? "")
    }

    /// A tab that ends before its launch was ever staged ran nothing there:
    /// the host side records the creation failed, and the tab says so.
    func testATabThatEndsBeforeItsLaunchWasStagedSaysNothingStarted() async throws {
        remote.stageAfterSpawn = true
        remote.stageGate = { try? await Task.sleep(for: .seconds(30)) }
        remote.collectResult = .nothing
        remote.unsentReason = "the connection ended before Temple could prepare the launch"
        let tab = await openRow()
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 255)
        await settle(tab.remote?.phase == .failedToStart(directory: tab.projectPath))
        XCTAssertEqual(remote.unproven, ["h1"])
        XCTAssertTrue(tab.launchFailure?.message.contains("the connection ended before Temple could prepare the launch") == true)
        XCTAssertNil(tab.remote?.stageOperation, "the staging was cancelled with the client")
    }

    // MARK: Unconfirmed conversations, diagnostics

    func testAnUnconfirmedConversationOffersStartANewSessionOrDiscard() async throws {
        remote.decision = true
        var discardedRows: [String] = []
        model.remoteTabs.rowIncarnation = { "inc-\($0)" }
        model.remoteTabs.discardHandler = { id, _, _ in discardedRows.append(id) }
        let row = Fixture.row("u", project: "/p", host: hostID)
        rows["u"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        await settle(tab.remote?.phase == .needsDecision(checked: true))
        XCTAssertTrue(factory.created.isEmpty, "never resumed blindly")
        model.remoteTabs.startNewSession(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.last?.startNew, true)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "h1"])
        // Discard instead, on another.
        let other = Fixture.row("v", project: "/p", host: hostID)
        rows["v"] = other
        model.openSession(other)
        let second = try XCTUnwrap(model.activeTab)
        await settle(second.remote?.phase == .needsDecision(checked: true))
        model.remoteTabs.discard(second)
        XCTAssertFalse(model.tabs.contains { $0 === second })
        await settle(discardedRows == ["v"])
        XCTAssertEqual(remote.discarded, ["v"])
    }

    /// The row's disposition is durable work too: a write that fails is
    /// said, never swallowed.
    func testADispositionThatFailsIsSaid() async throws {
        remote.decision = true
        model.remoteTabs.rowIncarnation = { "inc-\($0)" }
        model.remoteTabs.discardHandler = { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        var notices: [String] = []
        model.remoteTabs.noticeHandler = { _, text in notices.append(text) }
        let row = Fixture.row("w", project: "/p", host: hostID)
        rows["w"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        await settle(tab.remote?.phase == .needsDecision(checked: true))
        model.remoteTabs.discard(tab)
        await settle(!notices.isEmpty)
        XCTAssertEqual(remote.discarded, ["w"])
        XCTAssertEqual(notices.count, 1)
    }

    func testTypedInputConfirmsNothing() async throws {
        let tab = await openRow()
        let surface = try XCTUnwrap(tab.surface as? FakeTerminalSurface)
        model.surfaceDidSubmitInput(surface)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(remote.runs.allSatisfy { !$0.confirmed }, "Return at an ssh or trust prompt proves nothing")
    }

    func testCouldNotCheckOffersResumeToo() async throws {
        remote.decision = true
        remote.decisionChecked = false
        let row = Fixture.row("u", project: "/p", host: hostID)
        rows["u"] = row
        model.openSession(row)
        let tab = try XCTUnwrap(model.activeTab)
        await settle(tab.remote?.phase == .needsDecision(checked: false))
        model.remoteTabs.resumeUnconfirmed(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.last?.resumeUnconfirmed, true)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "h1"])
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

    func testACodexRowWithAnIDResumes() async throws {
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
