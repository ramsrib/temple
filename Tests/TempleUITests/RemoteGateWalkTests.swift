import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// Walks `RemoteCompletion`: every asynchronous completion in the remote
/// path that touches a tab, a row, a sheet or the saved tab set is held at
/// its await, the app is disrupted (the tab or sheet closed, the quit
/// begun, the host retired), the answer released, and the completion must
/// be suppressed by the gate with no effect. Each is also run undisturbed,
/// so the walk proves it reaches the gate at all.
@MainActor
final class RemoteGateWalkTests: XCTestCase {
    /// `otherInstance`: another Temple process attached to the run while
    /// the completion was held (its persisted attachment moved on).
    enum Disruption: CaseIterable { case none, close, quit, retire, otherInstance }

    let hostID = HostID(rawValue: "box")

    @MainActor final class Harness {
        let app: AppModel
        let db: TempleDB
        let remote: FakeRemoteHost
        let factory: FakeTerminalSurfaceFactory
        let host: HostID
        var directories: [String] = []
        var discards: [String] = []
        var sessionsSheet: RemoteSessionsSheetModel?
        var folderSheet: RemoteFolderSheetModel?
        var tab: SessionTab?
        let hold = Gate()

        @MainActor init(host: HostID) throws {
            self.host = host
            remote = FakeRemoteHost(host.rawValue)
            factory = FakeTerminalSurfaceFactory()
            let defaults = Fixture.uniqueDefaults()
            defaults.set(true, forKey: RemoteHostsModel.featureKey)
            defaults.set(try JSONEncoder().encode([["name": host.rawValue, "source": "config"]]), forKey: RemoteHostsModel.hostsKey)
            let local = Fixture.hostsWithoutFolderEvidence().entries[0]
            let hosts = HostRegistry(entries: [local, .init(source: FakeHostSource(host: host), launcher: remote)])
            db = try TempleDB.inMemory()
            app = AppModel(surfaceFactory: factory, database: db,
                           settings: SettingsStore(defaults: defaults), hostRegistry: hosts,
                           remoteHosts: RemoteHostsModel(defaults: defaults, readConfigAliases: { [] }))
            app.start()
            app.openSessions.earlyExitGraceSeconds = 0.5
            app.openSessions.remoteTabs.recordPollDelays = [0.01]
            app.openSessions.remoteTabs.identitySchedule = [0.01]
            app.openSessions.remoteTabs.identityInterval = 0.05
            app.openSessions.settleDelaySeconds = 60
            let original = app.openSessions.launchDirectoryHandler
            app.openSessions.launchDirectoryHandler = { [weak self] id, host, directory in
                self?.directories.append(directory)
                original?(id, host, directory)
            }
            app.openSessions.remoteTabs.discardHandler = { [weak self] id, _, _ in self?.discards.append(id) }
        }

        var gate: RemoteEffectGate { app.openSessions.remoteTabs.gate }
    }

    struct Scenario {
        let completion: RemoteCompletion
        /// Which disruptions apply (closing is the effect itself for some).
        let disruptions: [Disruption]
        /// Starts the completion; returns once it is held at its await.
        let arm: @MainActor (Harness) async throws -> Void
        let effect: @MainActor (Harness) -> Bool
    }

    private func settle(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func connectedTab(_ h: Harness, creating: Bool = true, id: String = "s1") async -> SessionTab {
        if !creating { h.remote.runs.append(.init(handle: "old-\(id)", sessionID: id, resume: false)) }
        let row = Fixture.row(id, project: "/home/u/p", host: h.host)
        Fixture.join([row], to: h.db)
        await settle { h.app.sessions.contains { $0.id == id } }
        h.app.openSessions.openSession(h.app.sessions.first { $0.id == id } ?? row)
        let tab = h.app.openSessions.activeTab!
        await settle { tab.hasLiveProcess }
        h.tab = tab
        return tab
    }

    /// A new Codex session on the host, connected and pending.
    private func pendingTab(_ h: Harness) async -> SessionTab {
        let tab = h.app.openSessions.newSession(agent: .codex, project: ProjectKey(host: h.host, path: "/home/u/p"))
        await settle { tab.hasLiveProcess }
        h.tab = tab
        return tab
    }

    private static let candidate = RemoteSuggestion(rolloutPath: "/home/u/.codex/sessions/rollout-x-c7.jsonl", sessionID: "c7",
                                                     firstPrompt: "hi", startedAt: Date(), directory: "/home/u/project")

    private var scenarios: [Scenario] {
        let tabDisruptions: [Disruption] = [.none, .close, .quit, .retire]
        let noClose: [Disruption] = [.none, .quit, .retire]
        let evidence: [Disruption] = [.none, .close, .quit, .retire, .otherInstance]
        return [
            Scenario(completion: .openResult, disruptions: tabDisruptions, arm: { h in
                h.remote.openGate = { await h.hold.wait() }
                let row = Fixture.row("s1", project: "/p", host: h.host)
                Fixture.join([row], to: h.db)
                h.app.openSessions.openSession(row)
                h.tab = h.app.openSessions.activeTab
                await self.settle { !h.remote.opens.isEmpty }
            }, effect: { $0.factory.created.count > 0 }),

            Scenario(completion: .pollDirectory, disruptions: evidence, arm: { h in
                h.remote.collectGate = { await h.hold.wait() }
                _ = await self.connectedTab(h)
                await self.settle { !h.remote.collects.isEmpty }
            }, effect: { !$0.directories.isEmpty }),

            Scenario(completion: .exitCollectDirectory, disruptions: evidence, arm: { h in
                h.remote.collectResult = .nothing
                let tab = await self.connectedTab(h)
                await self.settle { h.remote.collects.count >= 1 }
                try await Task.sleep(for: .milliseconds(50))
                h.remote.collectResult = .ok(directory: "/home/u/late")
                h.remote.collectGate = { await h.hold.wait() }
                let before = h.remote.collects.count
                (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 0)
                await self.settle { h.remote.collects.count > before }
            }, effect: { $0.directories.contains("/home/u/late") }),

            Scenario(completion: .exitFailedToStart, disruptions: evidence, arm: { h in
                h.remote.collectResult = .nothing
                let tab = await self.connectedTab(h)
                await self.settle { h.remote.collects.count >= 1 }
                try await Task.sleep(for: .milliseconds(50))
                h.remote.collectResult = .failedCD(directory: "/gone")
                h.remote.collectGate = { await h.hold.wait() }
                let before = h.remote.collects.count
                (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 0)
                await self.settle { h.remote.collects.count > before }
            }, effect: { $0.tab?.remote?.phase == .failedToStart(directory: "/gone") }),

            Scenario(completion: .exitVerdict, disruptions: evidence, arm: { h in
                h.remote.liveness = .unknown(reason: "verdict")
                h.remote.exitGate = { await h.hold.wait() }
                let tab = await self.connectedTab(h, creating: false)
                (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 0)
                await self.settle { tab.remote?.phase == .checking }
            }, effect: { $0.tab?.remote?.phase == .unknown(reason: "verdict") }),

            Scenario(completion: .exitDiagnostics, disruptions: evidence, arm: { h in
                h.remote.liveness = .absent
                h.remote.diagnosticsText = "boom"
                h.remote.diagnosticsGate = { await h.hold.wait() }
                let tab = await self.connectedTab(h)
                (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)
                await self.settle { tab.remote?.phase == .exitedEarly }
            }, effect: { !($0.tab?.remote?.diagnostics ?? []).isEmpty }),

            Scenario(completion: .storageNotice, disruptions: tabDisruptions, arm: { h in
                h.remote.collectResult = .nothing
                let tab = await self.connectedTab(h)
                await self.settle { h.remote.collects.count >= 1 }
                try await Task.sleep(for: .milliseconds(50))
                h.remote.collectResult = .storage("disk I/O error")
                h.remote.collectGate = { await h.hold.wait() }
                let before = h.remote.collects.count
                (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 0)
                await self.settle { h.remote.collects.count > before }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .explicitStopOutcome, disruptions: noClose, arm: { h in
                h.remote.stopGate = { _ in await h.hold.wait() }
                let tab = await self.connectedTab(h, creating: false)
                tab.activity = .running
                h.app.openSessions.requestClose(tabID: tab.id)
                h.app.openSessions.remoteTabs.confirmStop()
                await self.settle { !h.remote.stops.isEmpty }
            }, effect: { h in !h.app.openSessions.tabs.contains { $0 === h.tab } }),

            Scenario(completion: .trackedStopTabOutcome, disruptions: noClose, arm: { h in
                h.remote.stopGate = { _ in await h.hold.wait() }
                let tab = await self.connectedTab(h, creating: false)
                h.app.openSessions.remoteTabs.stopTracked(handle: tab.remote!.handle!, host: h.host, agent: .claude) { _ in }
                await self.settle { !h.remote.stops.isEmpty }
            }, effect: { h in !h.app.openSessions.tabs.contains { $0 === h.tab } }),

            Scenario(completion: .closeStopNotice, disruptions: noClose, arm: { h in
                h.remote.stopResult = .leftRunning(.hostDidNotAnswer, detail: nil)
                h.remote.stopGate = { _ in await h.hold.wait() }
                let tab = await self.connectedTab(h, creating: false)
                tab.activity = .idle
                h.app.openSessions.closeTab(tab.id)
                await self.settle { !h.remote.stops.isEmpty }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .rowStopNotice, disruptions: noClose, arm: { h in
                h.remote.stopResult = .leftRunning(.hostDidNotAnswer, detail: nil)
                h.remote.stopGate = { _ in await h.hold.wait() }
                h.remote.runs.append(.init(handle: "h9", sessionID: "s9", resume: true))
                h.app.openSessions.remoteTabs.stopSession(sessionID: "s9", host: h.host)
                await self.settle { !h.remote.stops.isEmpty }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .discardNotice, disruptions: noClose, arm: { h in
                h.remote.decision = true
                h.remote.discardError = CocoaError(.fileWriteUnknown)
                h.remote.discardGate = { await h.hold.wait() }
                let row = Fixture.row("s1", project: "/p", host: h.host)
                Fixture.join([row], to: h.db)
                h.app.openSessions.openSession(row)
                let tab = h.app.openSessions.activeTab!
                await self.settle { tab.remote?.phase == .needsDecision(checked: true) }
                h.app.openSessions.remoteTabs.discard(tab)
                await self.settle { !h.remote.discarded.isEmpty }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .settle, disruptions: noClose, arm: { h in
                h.app.openSessions.settleDelaySeconds = 0.4
                h.app.openSessions.titleQuietWindow = 0
                let tab = await self.connectedTab(h, creating: false)
                tab.activity = .running
            }, effect: { $0.tab?.activity == .idle }),

            Scenario(completion: .startupDeadline, disruptions: tabDisruptions, arm: { h in
                h.app.openSessions.remoteTabs.startupEvidenceDeadline = 0.4
                _ = await self.connectedTab(h, creating: false)
            }, effect: { $0.tab?.remote?.stillConnecting == true }),

            Scenario(completion: .stageFailure, disruptions: tabDisruptions, arm: { h in
                h.remote.stageAfterSpawn = true
                h.remote.stageResult = .failed("the record directory isn't private")
                h.remote.stageGate = { await h.hold.wait() }
                _ = await self.connectedTab(h, creating: false)
                await self.settle { !h.remote.stages.isEmpty }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .contactNotice, disruptions: noClose, arm: { h in
                h.remote.unnoticed = 2
                h.remote.contactGate = { await h.hold.wait() }
                h.app.contactHostsWithSessionsLeftRunning()
                try await Task.sleep(for: .milliseconds(50))
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .sheetLoad, disruptions: tabDisruptions, arm: { h in
                h.remote.trackedGate = { await h.hold.wait() }
                h.app.showRemoteSessions(h.host)
                let sheet = h.app.sessionsSheetModel(h.app.remoteSessionsSheet!)
                h.sessionsSheet = sheet
                sheet.load()
                try await Task.sleep(for: .milliseconds(50))
            }, effect: { $0.sessionsSheet?.listing != nil }),

            Scenario(completion: .sheetStopOutcome, disruptions: tabDisruptions, arm: { h in
                h.remote.stopGate = { _ in await h.hold.wait() }
                h.remote.runs.append(.init(handle: "h9", sessionID: "s9", resume: true))
                h.app.showRemoteSessions(h.host)
                let sheet = h.app.sessionsSheetModel(h.app.remoteSessionsSheet!)
                h.sessionsSheet = sheet
                sheet.stop(RemoteTrackedSession(handle: "h9", sessionID: "s9", agent: .claude,
                                                state: .present(attached: false), leftRunning: nil))
                await self.settle { !h.remote.stops.isEmpty }
            }, effect: { $0.sessionsSheet?.stopping.isEmpty == true }),

            // Codex identity (phase 1b)
            Scenario(completion: .pendingOpenResult, disruptions: tabDisruptions, arm: { h in
                h.remote.pendingOpenGate = { await h.hold.wait() }
                h.tab = h.app.openSessions.newSession(agent: .codex, project: ProjectKey(host: h.host, path: "/home/u/p"))
                await self.settle { !h.remote.pendingOpens.isEmpty }
            }, effect: { $0.factory.created.count > 0 }),

            // Closing a pending tab checks its identity once more on purpose
            // (testClosingAPendingTabChecksOnceMoreThenStops), so the close
            // disruption would admit that check's own answer.
            Scenario(completion: .identityResult, disruptions: noClose, arm: { h in
                h.remote.identityResult = .adopted("c9", directory: "/home/u/project")
                h.remote.identityGate = { await h.hold.wait() }
                _ = await self.pendingTab(h)
                await self.settle { !h.remote.identifies.isEmpty }
            }, effect: { $0.tab?.sessionID == "c9" }),

            Scenario(completion: .suggestionsLoaded, disruptions: tabDisruptions, arm: { h in
                h.remote.identityResult = .inconclusive("this host has no /proc", lasting: true, ended: false)
                h.remote.suggestionsResult = .candidates([Self.candidate])
                h.remote.suggestionsGate = { await h.hold.wait() }
                _ = await self.pendingTab(h)
                await self.settle { !h.remote.suggestionLookups.isEmpty }
            }, effect: { $0.tab?.remote?.suggestions.isEmpty == false }),

            Scenario(completion: .confirmResult, disruptions: tabDisruptions, arm: { h in
                h.app.openSessions.remoteTabs.identitySchedule = [60]
                h.remote.confirmResult = .taken
                h.remote.confirmGate = { await h.hold.wait() }
                let tab = await self.pendingTab(h)
                h.app.openSessions.remoteTabs.confirm(Self.candidate, in: tab)
                await self.settle { !h.remote.confirms.isEmpty }
            }, effect: { $0.tab?.remote?.identityNote == RemoteCopy.couldNotTell }),

            Scenario(completion: .pendingStopOutcome, disruptions: noClose, arm: { h in
                h.app.openSessions.remoteTabs.identitySchedule = [60]
                h.remote.stopGate = { _ in await h.hold.wait() }
                let tab = await self.pendingTab(h)
                tab.inputSubmitted = true
                tab.activity = .idle
                h.app.openSessions.closeTab(tab.id)
                await self.settle { !h.remote.stops.isEmpty }
            }, effect: { $0.tab?.remote?.phase == .endedPending }),

            Scenario(completion: .pendingRestore, disruptions: noClose, arm: { h in
                h.remote.pending = [.init(handle: "p7", directory: "/home/u/project")]
                h.remote.pendingRunsGate = { await h.hold.wait() }
                h.app.openSessions.remoteTabs.restorePending(hosts: [h.host])
                try await Task.sleep(for: .milliseconds(50))
            }, effect: { h in h.app.openSessions.tabs.contains { $0.remote?.handle == "p7" } }),

            Scenario(completion: .pendingDiscardNotice, disruptions: noClose, arm: { h in
                h.remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true)]
                h.app.openSessions.remoteTabs.restorePending(hosts: [h.host])
                await self.settle { h.app.openSessions.tabs.contains { $0.remote?.handle == "p7" } }
                let tab = try XCTUnwrap(h.app.openSessions.tabs.first { $0.remote?.handle == "p7" })
                h.remote.dismissRunError = CocoaError(.fileWriteUnknown)
                h.remote.dismissRunGate = { await h.hold.wait() }
                h.app.openSessions.remoteTabs.discardPending(tab)
                await self.settle { !h.remote.dismissedRuns.isEmpty }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .identityNotice, disruptions: noClose, arm: { h in
                h.app.openSessions.remoteTabs.identitySchedule = [60]
                h.remote.declineError = CocoaError(.fileWriteUnknown)
                h.remote.declineGate = { await h.hold.wait() }
                let tab = await self.pendingTab(h)
                h.app.openSessions.remoteTabs.decline(Self.candidate, in: tab)
                await self.settle { !h.remote.declines.isEmpty }
            }, effect: { $0.app.remoteNotice != nil }),

            Scenario(completion: .folderCheckResult, disruptions: tabDisruptions, arm: { h in
                h.remote.folder = .exists(resolved: "/home/u/new")
                h.remote.folderGate = { await h.hold.wait() }
                h.app.chooseRemoteFolder(host: h.host, agent: .claude)
                let sheet = h.app.folderSheetModel(h.app.remoteFolderSheet!)
                h.folderSheet = sheet
                sheet.path = "~/new"
                sheet.confirm()
                try await Task.sleep(for: .milliseconds(50))
            }, effect: { $0.folderSheet?.check != .checking }),
        ]
    }

    private func disrupt(_ h: Harness, _ disruption: Disruption) {
        switch disruption {
        case .none:
            break
        case .close:
            if h.sessionsSheet != nil { h.app.remoteSessionsSheet = nil; h.sessionsSheet?.dismissed() }
            if h.folderSheet != nil { h.app.remoteFolderSheet = nil; h.folderSheet?.dismissed() }
            if let tab = h.tab, h.sessionsSheet == nil, h.folderSheet == nil { h.app.openSessions.closeTab(tab.id) }
        case .quit:
            h.app.openSessions.prepareForQuit()
            _ = h.app.openSessions.quitDrainPlan()
        case .retire:
            // As AppModel retires a host before its entry goes.
            h.app.openSessions.remoteTabs.retireHost(h.host)
            h.app.hostBox.value = h.app.hostBox.value.removing(h.host)
        case .otherInstance:
            if let handle = h.tab?.remote?.handle, let index = h.remote.runs.firstIndex(where: { $0.handle == handle }) {
                h.remote.runs[index].attachment += 1
            }
        }
    }

    /// Coverage of `RemoteCompletion`, not completeness against the source:
    /// a new completion must be added to the enum (and here) by hand; the
    /// enum's documentation lists the mechanisms deliberately outside it.
    func testEveryCompletionIsGatedAfterCloseQuitAndRetirement() async throws {
        XCTAssertEqual(Set(scenarios.map(\.completion)), Set(RemoteCompletion.allCases), "the walk covers the whole list")
        for scenario in scenarios {
            for disruption in scenario.disruptions {
                let h = try Harness(host: hostID)
                try await scenario.arm(h)
                let name = "\(scenario.completion) after \(disruption)"
                let suppressedBefore = h.gate.suppressed[scenario.completion, default: 0]
                let persistedBefore = h.app.openSessions.tabs.count
                disrupt(h, disruption)
                await h.hold.open()
                if disruption == .none {
                    await settle { h.gate.admitted[scenario.completion, default: 0] > 0 }
                    await settle { scenario.effect(h) }
                    XCTAssertGreaterThan(h.gate.admitted[scenario.completion, default: 0], 0, "\(name): reaches the gate")
                    XCTAssertTrue(scenario.effect(h), "\(name): has its effect")
                } else {
                    // A timer completion (settle, the startup deadline)
                    // fires on its own schedule.
                    await settle({ h.gate.suppressed[scenario.completion, default: 0] > suppressedBefore }, timeout: 3)
                    try await Task.sleep(for: .milliseconds(50))
                    XCTAssertGreaterThan(h.gate.suppressed[scenario.completion, default: 0], suppressedBefore, "\(name): suppressed")
                    XCTAssertEqual(h.gate.admitted[scenario.completion, default: 0], 0, "\(name): never admitted")
                    XCTAssertFalse(scenario.effect(h), "\(name): no effect")
                    if disruption == .quit {
                        XCTAssertEqual(h.app.openSessions.tabs.count, persistedBefore, "\(name): the frozen tab set is untouched")
                    }
                }
            }
        }
    }

    /// Discard is durable work: once the remote dismissal is written, the
    /// row's disposition happens even when the quit begins or the host is
    /// retired meanwhile; only presentation is gated.
    func testDiscardFinishesItsDurableWorkThroughQuitAndRetirement() async throws {
        for disruption in [Disruption.quit, .retire] {
            let h = try Harness(host: hostID)
            h.remote.decision = true
            h.remote.discardGate = { await h.hold.wait() }
            let row = Fixture.row("s1", project: "/p", host: hostID)
            Fixture.join([row], to: h.db)
            h.app.openSessions.openSession(row)
            let tab = try XCTUnwrap(h.app.openSessions.activeTab)
            await settle { tab.remote?.phase == .needsDecision(checked: true) }
            h.app.openSessions.remoteTabs.discard(tab)
            await settle { !h.remote.discarded.isEmpty }
            disrupt(h, disruption)
            await h.hold.open()
            await settle { h.discards == ["s1"] }
            XCTAssertEqual(h.discards, ["s1"], "\(disruption): the row's disposition still happened")
        }
    }

    /// The row disposition is for the membership Discard was chosen for: a
    /// row that left and joined again meanwhile is left alone.
    func testDiscardLeavesAReplacedRowAlone() async throws {
        let h = try Harness(host: hostID)
        var handled: [String] = []
        h.app.openSessions.remoteTabs.discardHandler = { _, _, incarnation in handled.append(incarnation) }
        h.remote.decision = true
        let row = Fixture.row("s1", project: "/p", host: hostID)
        Fixture.join([row], to: h.db)
        await settle { h.app.overlay.rows["s1"] != nil }
        let before = h.app.overlay.rows["s1"]?.incarnation
        h.app.openSessions.openSession(row)
        let tab = try XCTUnwrap(h.app.openSessions.activeTab)
        await settle { tab.remote?.phase == .needsDecision(checked: true) }
        h.app.openSessions.remoteTabs.discard(tab)
        await settle { !handled.isEmpty }
        XCTAssertEqual(handled, [try XCTUnwrap(before)], "the incarnation captured when Discard was chosen travels with it")
    }
}
