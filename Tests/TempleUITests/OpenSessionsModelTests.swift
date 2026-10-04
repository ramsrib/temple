import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

@MainActor
final class OpenSessionsModelTests: XCTestCase {

    private func row(_ id: String = "row", agent: Agent? = .codex,
                     directory: String? = "/row-directory",
                     resolution: MemberResolution? = nil) -> Session {
        Session(state: SessionState(id: id, pinned: false, archived: false,
            customName: "Row title", color: nil, generatedTitle: nil,
            lastOpenedAt: nil, joinedVia: .imported, joinedAt: nil,
            agent: agent, directory: directory, title: "Stored title"), resolution: resolution)
    }

    func testOpeningARowWithoutATranscriptSpawnsFromRowFields() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in LocalHostLauncher(binaryPath: { "/configured/" + $0.binaryName }, extraArgs: { _ in ["--flag"] }, folderEvidence: { _ in .unknown }) })
        model.openSession(row(resolution: .confirmedAbsent))
        let command = try XCTUnwrap(factory.created.first?.startedCommand)
        XCTAssertEqual(command.agentArgv, ["/configured/codex", "--flag", "resume", "row"])
        XCTAssertEqual(command.cwd, "/row-directory")
        XCTAssertEqual(model.activeTab?.title, "Row title")
        XCTAssertEqual(model.activeTab?.host, .local)
        XCTAssertEqual(command.env["TERM_PROGRAM"], "Temple")
        model.openSession(row())
        XCTAssertEqual(factory.created.count, 1, "Reuse the existing tab")
    }

    func testOpeningUsesRowDirectoryNotTranscriptCwd() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.sessionRow = { _ in self.row(agent: .claude) }
        model.openSession(Fixture.session("row", agent: .codex, project: "/transcript-cwd", title: "Transcript"))
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/row-directory")
        XCTAssertEqual(factory.created.first?.startedCommand?.agentArgv, ["claude", "--resume", "row"])
        XCTAssertEqual(model.activeTab?.title, "Row title")
    }

    func testARowWithoutDirectoryIsNotSpawned() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        var joins = 0
        model.openedHandler = { _ in joins += 1; return .joined }
        model.openSession(row(directory: nil))
        model.openSession(row(agent: nil))
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(joins, 0)
    }

    func testTheLocalLaunchPassesTheAgentArgvPositionallyBehindTheWrapper() throws {
        let markers = try temporaryDirectory()
        let launcher = LocalHostLauncher(binaryPath: { _ in "/opt/my tools/codex" }, extraArgs: { _ in ["--flag='x'"] },
                                         folderEvidence: { _ in .unknown }, markerDirectory: markers)
        let launch = try launcher.prepare(AgentLaunchSpec(agent: .codex, mode: .resume(sessionID: "id with spaces"),
                                                          directory: "/a folder/it's here", host: .local))
        XCTAssertEqual(launch.displayArgv, ["/opt/my tools/codex", "--flag='x'", "resume", "id with spaces"])
        XCTAssertEqual(Array(launch.command.argv.prefix(6)),
                       ["/usr/bin/env", "/bin/sh", "-c", LocalHostLauncher.wrapperScript, "temple-launch", "/a folder/it's here"])
        XCTAssertEqual(launch.command.agentArgv, launch.displayArgv)
        XCTAssertEqual(launch.command.cwd, "/a folder/it's here")
        XCTAssertEqual(launch.command.env, [:], "the launcher adds no variables; the spawn applies identity")
        let marker = try XCTUnwrap(launch.command.launchMarker)
        XCTAssertTrue(marker.hasPrefix(markers.path + "/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: marker)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "created before the spawn, private")
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 0)
        let channel = try XCTUnwrap(launch.result)
        channel.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the launcher's marker goes with the launch")
        XCTAssertEqual(launcher.availability(.claude), .available)
    }

    func testOpenNoLongerWaitsForResolution() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "row", via: .imported, agent: .claude,
            core: SessionCore(directory: "/row-directory", title: "Stored title"))
        let factory = FakeTerminalSurfaceFactory()
        let app = AppModel(surfaceFactory: factory, engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["row": .resolving]))
        app.openSession(id: "row")
        XCTAssertEqual(factory.created.count, 1)
        let tab = try XCTUnwrap(app.openSessions.activeTab)
        app.openSessions.surface(try XCTUnwrap(tab.surface), didChangeState: .exited(status: 1))
        XCTAssertFalse(tab.resumeTargetMissing)
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["row": .unreadable]))
        XCTAssertNil(app.openSessions.sessionKnown("row"))
        XCTAssertFalse(tab.resumeTargetMissing)
        app.receiveEngineSnapshot(EngineSnapshot(generation: 3, resolutions: ["row": .confirmedAbsent]))
        XCTAssertTrue(tab.resumeTargetMissing)
        // Older generations cannot replace the completed evidence.
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: [:]))
        XCTAssertEqual(app.openSessions.sessionKnown("row"), false)
    }

    func testRestoreAndReopenPreferTheRowAndKeepRestoreInert() throws {
        let factory = FakeTerminalSurfaceFactory()
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        persistence.save([PersistedTab(sessionID: "row", agent: .claude, projectPath: "/saved", title: "Saved")])
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(), persistence: persistence)
        model.sessionRow = { _ in self.row() }
        model.restore()
        XCTAssertTrue(factory.created.isEmpty)
        let tab = try XCTUnwrap(model.tabs.first)
        XCTAssertEqual(tab.title, "Row title")
        XCTAssertEqual(tab.projectPath, "/row-directory")
        XCTAssertEqual(tab.host, .local)
        model.activate(tab)
        XCTAssertEqual(factory.created.first?.startedCommand?.agentArgv, ["codex", "resume", "row"])
        model.closeTab(tab.id)
        model.reopenLastClosedTab()
        XCTAssertEqual(factory.created.count, 2)
        XCTAssertEqual(model.activeTab?.title, "Row title")
    }

    func testCopyResumeCommandPrefersTheRowAndKeepsLegacyFallback() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "row", via: .imported, agent: .claude,
            core: SessionCore(directory: "/row-directory"))
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        XCTAssertEqual(app.resumeArgv(for: Fixture.session("row", agent: .codex, project: "/transcript")),
            ["claude", "--resume", "row"])
        XCTAssertEqual(app.resumeArgv(for: Fixture.session("outside", agent: .codex, project: "/transcript")),
            ["codex", "resume", "outside"])
    }

    func testAnInertRestoredChipUsesFactsFilledBeforeItsFirstSpawn() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "row", via: .imported, agent: .claude)
        var current = Session(state: try XCTUnwrap(db.sessionState("row")))
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save([PersistedTab(sessionID: "row", agent: .claude, projectPath: "/saved", title: "Saved")])
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(), persistence: persistence)
        model.sessionRow = { _ in current }
        model.restore()
        let tab = try XCTUnwrap(model.tabs.first)
        XCTAssertTrue(factory.created.isEmpty)
        _ = try db.fillCoreFields(sessionID: "row", host: .local, directory: "/filled", title: "Filled")
        current = Session(state: try XCTUnwrap(db.sessionState("row")))
        model.activate(tab)
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/filled")
        XCTAssertEqual(tab.title, "Filled")
        XCTAssertEqual(tab.projectPath, "/filled")
    }

    func testRestoreWithoutARowJoinsOnlyAtFirstSpawn() throws {
        for isActive in [false, true] {
            let directory = try temporaryDirectory()
            let db = try TempleDB.inMemory()
            let overlay = SessionOverlayStore(db: db)
            let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
            persistence.save([PersistedTab(sessionID: "legacy", agent: .codex,
                projectPath: directory.path, title: "Saved", isActive: isActive)])
            let factory = FakeTerminalSurfaceFactory()
            let model = writerModel(db: db, overlay: overlay, persistence: persistence, factory: factory)
            model.sessionRow = { id in overlay.rows[id].map { Session(state: $0) } }
            model.restore()
            if !isActive {
                XCTAssertNil(try db.sessionState("legacy"), "An inert chip must not join")
                XCTAssertTrue(factory.created.isEmpty)
                model.activate(try XCTUnwrap(model.tabs.first))
            }
            XCTAssertEqual(factory.created.count, 1)
            XCTAssertEqual(factory.created.first?.startedCommand?.cwd, directory.path)
            model.drainLaunchResults()
            XCTAssertEqual(try db.sessionState("legacy")?.directory, directory.path)
            XCTAssertEqual(try db.sessionState("legacy")?.joinedVia, .opened)
        }
    }

    /// The row wins where it knows; where it does not, the chip's own saved
    /// facts stand in, and the spawn records the folder on the row.
    func testDelayedChipActivationCompletesAnIncompleteRowFromTheChip() throws {
        for missingAgent in [false, true] {
            let directory = try temporaryDirectory()
            let db = try TempleDB.inMemory()
            let overlay = SessionOverlayStore(db: db)
            let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
            persistence.save([PersistedTab(sessionID: "legacy", agent: .codex,
                projectPath: directory.path, title: "Saved")])
            let factory = FakeTerminalSurfaceFactory()
            let model = writerModel(db: db, overlay: overlay, persistence: persistence, factory: factory)
            model.sessionRow = { id in overlay.rows[id].map { Session(state: $0) } }
            model.restore()
            XCTAssertNil(try db.sessionState("legacy"))
            overlay.join("legacy", via: .imported, agent: missingAgent ? nil : .codex,
                core: SessionCore(directory: missingAgent ? directory.path : nil))
            let tab = try XCTUnwrap(model.tabs.first)
            model.activate(tab)
            model.activate(tab)
            XCTAssertEqual(factory.created.count, 1)
            XCTAssertEqual(factory.created.first?.startedCommand?.agentArgv, ["codex", "resume", "legacy"])
            XCTAssertEqual(factory.created.first?.startedCommand?.cwd, directory.path)
            XCTAssertEqual(model.activeTabID, tab.id)
            model.drainLaunchResults()
            XCTAssertEqual(try db.sessionState("legacy")?.directory, directory.path)
            XCTAssertEqual(try db.sessionState("legacy")?.directorySource, .tab)
        }
    }

    func testActiveRestoreKeepsTheSavedTitleWhenTheRowHasNoTitle() throws {
        try assertUntitledRowKeepsSavedTitle(isActive: true)
    }

    func testLazyActivationKeepsTheSavedTitleWhenTheRowHasNoTitle() throws {
        try assertUntitledRowKeepsSavedTitle(isActive: false)
    }

    private func assertUntitledRowKeepsSavedTitle(isActive: Bool) throws {
        for agent in Agent.allCases {
            let db = try TempleDB.inMemory()
            try db.join(sessionID: "row", via: .opened, agent: agent,
                core: SessionCore(directory: "/row-directory"))
            let current = Session(state: try XCTUnwrap(db.sessionState("row")))
            let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
            persistence.save([PersistedTab(sessionID: "row", agent: agent,
                projectPath: "/saved", title: "Saved conversation", isActive: isActive)])
            let factory = FakeTerminalSurfaceFactory()
            let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(), persistence: persistence)
            model.sessionRow = { _ in current }
            model.restore()
            let tab = try XCTUnwrap(model.tabs.first)
            XCTAssertEqual(tab.title, "Saved conversation")
            if !isActive {
                XCTAssertTrue(factory.created.isEmpty)
                model.activate(tab)
            }
            XCTAssertEqual(tab.title, "Saved conversation")
            XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/row-directory")
        }
    }

    func testTheLauncherPreparesExactlyOncePerSpawnAcrossAllOpenPaths() throws {
        let factory = FakeTerminalSurfaceFactory()
        let wrapper = CountingLauncher()
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save([PersistedTab(sessionID: "restored", agent: .codex, projectPath: "/saved", title: "Saved")])
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: persistence, launcherForHost: { _ in wrapper })
        model.restore()
        let restored = try XCTUnwrap(model.tabs.first)
        XCTAssertEqual(wrapper.count, 0)
        let fresh = model.newSession(agent: .claude, project: Fixture.key("/new"))
        XCTAssertEqual(wrapper.count, 1)
        model.activate(fresh)
        model.activate(fresh)
        XCTAssertEqual(wrapper.count, 1)
        model.activate(restored)
        XCTAssertEqual(wrapper.count, 2)
        model.activate(restored)
        XCTAssertEqual(wrapper.count, 2)
        model.closeTab(restored.id)
        model.reopenLastClosedTab()
        XCTAssertEqual(wrapper.count, 3)
        model.openSession(Fixture.session("restored", agent: .codex, project: "/saved"))
        model.focusActiveTerminal()
        XCTAssertEqual(wrapper.count, 3)
        model.openSession(row())
        XCTAssertEqual(wrapper.count, 4)
        model.openSession(row())
        XCTAssertEqual(wrapper.count, 4)
        XCTAssertEqual(wrapper.count, factory.created.count)
    }

    func testSpawnAppliesTerminalIdentityAfterTheLauncherPrepares() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in ObservingLauncher() })
        model.openSession(row())
        let command = try XCTUnwrap(factory.created.first?.startedCommand)
        XCTAssertEqual(command.env["IDENTITY_AT_WRAP"], "absent")
        XCTAssertEqual(command.env["TERM_PROGRAM"], "Temple")
    }

    private func writerModel(db: TempleDB, overlay: SessionOverlayStore,
                             persistence: TabPersistence? = nil,
                             factory: FakeTerminalSurfaceFactory? = nil,
                             now: @escaping () -> Date = Date.init) -> OpenSessionsModel {
        let model = OpenSessionsModel(surfaceFactory: factory ?? FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default }, runtime: SessionRuntimeController(),
            registry: InMemoryProcessRegistry(),
            persistence: persistence ?? UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()), now: now,
            directoryEvidence: Fixture.existingFoldersOnly)
        model.openedHandler = { open in
            let result = overlay.join(open.id, via: open.via, agent: open.agent, locator: open.locator, core: SessionCore(host: open.host))
            if open.via == .opened { overlay.recordOpened(open.id, host: open.host) }
            return result
        }
        model.touchHandler = { overlay.touch($0, host: $1, at: $2) }
        model.launchDirectoryHandler = { overlay.observeLaunchDirectory($0, host: $1, $2) }
        return model
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testThrowingStartDoesNotWriteLaunchFacts() throws {
        let directory = try temporaryDirectory()
        for agent in Agent.allCases {
            let db = try TempleDB.inMemory()
            let overlay = SessionOverlayStore(db: db)
            let factory = FakeTerminalSurfaceFactory()
            factory.configure = { $0.startError = CocoaError(.executableNotLoadable) }
            let model = writerModel(db: db, overlay: overlay, factory: factory)
            let tab = model.newSession(agent: agent, project: Fixture.key(directory.path))
            if agent == .codex { model.adopt(sessionID: "codex-id", for: tab.id) }
            let row = try XCTUnwrap(db.sessionState(try XCTUnwrap(tab.sessionID)))
            XCTAssertNil(row.directory)
            XCTAssertNil(row.directorySource)
            XCTAssertNil(tab.launchObservation)
            XCTAssertNil(overlay.rows[row.id]?.lastActiveAt)
        }
    }

    func testNonexistentOrFileCwdDoesNotWriteLaunchDirectory() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        for cwd in [directory.appendingPathComponent("missing"), file] {
            for agent in Agent.allCases {
                let db = try TempleDB.inMemory()
                let overlay = SessionOverlayStore(db: db)
                let model = writerModel(db: db, overlay: overlay)
                let tab = model.newSession(agent: agent, project: Fixture.key(cwd.path))
                if agent == .codex { model.adopt(sessionID: "codex-id", for: tab.id) }
                let row = try XCTUnwrap(db.sessionState(try XCTUnwrap(tab.sessionID)))
                XCTAssertNil(row.directory)
                XCTAssertNil(row.directorySource)
                XCTAssertNil(tab.launchObservation?.directory)
            }
        }
    }

    func testCodexAdoptionUsesOriginalSpawnTime() throws {
        let db = try TempleDB.inMemory()
        var date = Date(timeIntervalSince1970: 100)
        let overlay = SessionOverlayStore(db: db, now: { date }, scheduleTouch: { _, _ in {} })
        let model = writerModel(db: db, overlay: overlay, now: { date })
        let tab = model.newSession(agent: .codex, project: Fixture.key(try temporaryDirectory().path))
        date = Date(timeIntervalSince1970: 200)
        model.adopt(sessionID: "codex-id", for: tab.id)
        overlay.flushPendingTouches()
        XCTAssertEqual(overlay.rows["codex-id"]?.lastActiveAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try db.sessionState("codex-id")?.lastActiveAt, Date(timeIntervalSince1970: 100))
    }

    func testTouchFlushCancelsItsScheduledCallback() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "a", via: .created)
        var callbacks: [@MainActor () -> Void] = []
        var cancelled: Set<Int> = []
        var date = Date(timeIntervalSince1970: 100)
        let overlay = SessionOverlayStore(db: db, now: { date }, scheduleTouch: { _, callback in
            let index = callbacks.count
            callbacks.append { if !cancelled.contains(index) { callback() } }
            return { cancelled.insert(index) }
        })
        overlay.touch("a", host: .local)
        overlay.flushPendingTouches()
        XCTAssertEqual(cancelled, [0])
        date = Date(timeIntervalSince1970: 200)
        overlay.touch("a", host: .local)
        callbacks[0]()
        XCTAssertEqual(try db.sessionState("a")?.lastActiveAt, Date(timeIntervalSince1970: 100))
        callbacks[1]()
        XCTAssertEqual(try db.sessionState("a")?.lastActiveAt, date)
        XCTAssertEqual(cancelled, [0, 1])
    }

    func testOpeningATabWritesDirectoryAsTabSourced() throws {
        let directory = try temporaryDirectory()
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "a", via: .imported,
                    core: SessionCore(directory: "/transcript", directorySource: .transcript))
        let overlay = SessionOverlayStore(db: db)
        let model = writerModel(db: db, overlay: overlay)
        model.openSession(Fixture.session("a", project: directory.path))
        XCTAssertEqual(try db.sessionState("a")?.directory, "/transcript", "nothing is recorded until the launch reports the folder")
        model.drainLaunchResults()
        XCTAssertEqual(try db.sessionState("a")?.directory, directory.path)
        XCTAssertEqual(try db.sessionState("a")?.directorySource, .tab)
        XCTAssertEqual(try db.sessionState("a")?.host, .local)
        try db.fillCoreFields(sessionID: "a", host: .local, directory: "/later-transcript")
        XCTAssertEqual(try db.sessionState("a")?.directory, directory.path)
    }

    func testCodexAdoptionWritesTheLaunchDirectory() throws {
        let directory = try temporaryDirectory()
        let db = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: db)
        let model = writerModel(db: db, overlay: overlay)
        let tab = model.newSession(agent: .codex, project: Fixture.key(directory.path))
        model.drainLaunchResults()   // the wrapper reports at spawn, long before adoption
        try FileManager.default.removeItem(at: directory)
        model.adopt(sessionID: "codex-id", for: tab.id)
        XCTAssertEqual(try db.sessionState("codex-id")?.directory, directory.path)
        XCTAssertEqual(try db.sessionState("codex-id")?.directorySource, .tab)
        XCTAssertNotNil(overlay.rows["codex-id"]?.lastActiveAt)
    }

    func testRestoredChipWritesNoDirectoryUntilItSpawns() throws {
        let directory = try temporaryDirectory()
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "a", via: .opened,
                    core: SessionCore(directory: "/old", directorySource: .tab))
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save([PersistedTab(sessionID: "a", agent: .claude, projectPath: directory.path, title: "A")])
        let overlay = SessionOverlayStore(db: db)
        let model = writerModel(db: db, overlay: overlay, persistence: persistence)
        model.restore()
        XCTAssertEqual(try db.sessionState("a")?.directory, "/old")
        XCTAssertFalse(try XCTUnwrap(model.tabs.first).hasSurface)
        model.activate(try XCTUnwrap(model.tabs.first))
        model.drainLaunchResults()
        XCTAssertEqual(try db.sessionState("a")?.directory, directory.path)
        XCTAssertEqual(try db.sessionState("a")?.directorySource, .tab)
    }

    func testTouchIsImmediateInMemoryCoalescedOnDiskAndMonotonic() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "a", via: .created)
        try db.join(sessionID: "b", via: .created)
        var date = Date(timeIntervalSince1970: 100)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let overlay = SessionOverlayStore(db: db, now: { date }, scheduleTouch: { delay, action in
            scheduled.append((delay, action)); return {}
        })
        overlay.touch("a", host: .local)
        XCTAssertEqual(overlay.rows["a"]?.lastActiveAt, date)
        XCTAssertNil(try db.sessionState("a")?.lastActiveAt)
        date = Date(timeIntervalSince1970: 120)
        overlay.touch("a", host: .local)
        date = Date(timeIntervalSince1970: 110)
        overlay.touch("a", host: .local)
        overlay.touch("b", host: .local)
        XCTAssertEqual(scheduled.count, 2, "each session owns a coalescing window")
        XCTAssertEqual(scheduled.map { $0.0 }, [30, 30])
        XCTAssertEqual(overlay.rows["a"]?.lastActiveAt, Date(timeIntervalSince1970: 120))
        scheduled[0].1()
        XCTAssertEqual(try db.sessionState("a")?.lastActiveAt, Date(timeIntervalSince1970: 120))
        XCTAssertNil(try db.sessionState("b")?.lastActiveAt)
        date = Date(timeIntervalSince1970: 130)
        overlay.touch("a", host: .local)
        try db.touch(sessionID: "a", host: .local, at: Date(timeIntervalSince1970: 200))
        overlay.flushPendingTouches()
        XCTAssertEqual(try db.sessionState("a")?.lastActiveAt, Date(timeIntervalSince1970: 200))
    }

    func testQuitFlushesButDoesNotTouch() throws {
        let db = try TempleDB.inMemory()
        var date = Date(timeIntervalSince1970: 100)
        let overlay = SessionOverlayStore(db: db, now: { date }, scheduleTouch: { _, _ in {} })
        let model = writerModel(db: db, overlay: overlay, now: { date })
        let tab = model.newSession(agent: .claude, project: Fixture.key("/launch"))
        let id = try XCTUnwrap(tab.sessionID)
        overlay.recordGeneratedTitle("Pending title", for: id)
        date = Date(timeIntervalSince1970: 200)
        model.prepareForQuit()
        overlay.flushPendingTitles()
        overlay.flushPendingTouches()
        model.surface(try XCTUnwrap(tab.surface), didChangeState: .exited(status: 0))
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        model.surface(try XCTUnwrap(tab.surface), didUpdateTitle: "Shutdown")
        XCTAssertEqual(overlay.rows[id]?.lastActiveAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try db.sessionState(id)?.lastActiveAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try db.sessionState(id)?.title, "Pending title")
    }

    func testRestoreDoesNotTouchInertChips() throws {
        let db = try TempleDB.inMemory()
        let date = Date(timeIntervalSince1970: 100)
        try db.join(sessionID: "a", via: .opened, core: SessionCore(lastActiveAt: date))
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save([PersistedTab(sessionID: "a", agent: .claude, projectPath: "/p", title: "A")])
        let overlay = SessionOverlayStore(db: db, now: { date.addingTimeInterval(50) }, scheduleTouch: { _, _ in {} })
        let model = writerModel(db: db, overlay: overlay, persistence: persistence, now: { date.addingTimeInterval(50) })
        model.restore()
        overlay.flushPendingTouches()
        XCTAssertEqual(overlay.rows["a"]?.lastActiveAt, date)
        XCTAssertEqual(try db.sessionState("a")?.lastActiveAt, date)
        model.activate(try XCTUnwrap(model.tabs.first))
        XCTAssertEqual(overlay.rows["a"]?.lastActiveAt, date.addingTimeInterval(50))
    }

    func testALateAbsentVerdictAnnotatesAnExitedTab() throws {
        var known: Bool?
        let model = modelForResumeTests(sessionKnown: { _ in known })
        model.openSession(Fixture.session("a", project: "/p"))
        let tab = try XCTUnwrap(model.tabs.first)
        model.surface(try XCTUnwrap(tab.surface), didChangeState: .exited(status: 1))
        XCTAssertFalse(tab.resumeTargetMissing)
        model.refreshExitedResumeDiagnoses()
        XCTAssertFalse(tab.resumeTargetMissing)
        known = false
        model.refreshExitedResumeDiagnoses()
        XCTAssertTrue(tab.resumeTargetMissing)
    }

    func testADeletedWorkingDirectoryGetsItsOwnLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = modelForResumeTests(sessionKnown: { _ in true }, directoryEvidence: Fixture.localDirectoryEvidence)
        model.openSession(Fixture.session("a", project: directory.path))
        let tab = try XCTUnwrap(model.tabs.first)
        try FileManager.default.removeItem(at: directory)
        model.surface(try XCTUnwrap(tab.surface), didChangeState: .exited(status: 1))
        XCTAssertFalse(tab.resumeTargetMissing)
        // The owning host is asked after the exit (asynchronously).
        let deadline = Date().addingTimeInterval(2)
        while tab.missingWorkingDirectory == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tab.missingWorkingDirectoryMessage, "The folder \(directory.path) no longer exists")
    }

    func testActivitySignalsTouchButQuietAgentsAndRefocusingDoNot() throws {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var touched: [String] = []
        model.touchHandler = { id, _, _ in touched.append(id) }
        let tab = model.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        let surface = try XCTUnwrap(tab.surface as? FakeTerminalSurface)
        XCTAssertEqual(touched, [id])
        touched.removeAll()
        model.activate(tab)
        model.surface(surface, didUpdateTitle: tab.title)
        XCTAssertTrue(touched.isEmpty)
        model.surface(surface, didUpdateTitle: "Changed")
        model.surfaceDidSubmitInput(surface)
        surface.simulateExit(status: 1)
        model.closeTab(tab.id)
        XCTAssertEqual(touched, [id, id, id, id])
    }

    func testOpenSessionSpawnsSurfaceAndActivates() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let s = Fixture.session("a", project: "/p/a")

        model.openSession(s)

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a")
        XCTAssertNotNil(model.tabs.first?.surface)          // spawned on open
        XCTAssertEqual(factory.created.count, 1)
    }

    func testReuseOrFocusNeverDuplicates() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let s = Fixture.session("a", project: "/p/a")

        model.openSession(s)
        model.openSession(s)

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(factory.created.count, 1)            // no second surface
    }

    func testPerProjectScopingSwapsWithActiveTab() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))

        // Active project is now /p/b → only its tab visible.
        XCTAssertEqual(model.activeProjectKey?.path, "/p/b")
        XCTAssertEqual(model.visibleTabs.map(\.sessionID), ["b1"])

        // Focusing an /p/a session swaps the bar back.
        model.openSession(Fixture.session("a1", project: "/p/a"))
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a")
        XCTAssertEqual(Set(model.visibleTabs.compactMap(\.sessionID)), ["a1", "a2"])
    }

    func testAgentRetitleIsHandedUpWithItsSessionID() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        var recorded: [String: String] = [:]
        model.titleHandler = { recorded[$0] = $2 }

        let surface = try! XCTUnwrap(model.tabs.first?.surface)
        model.surface(surface, didUpdateTitle: "Fixing the shift+enter encoding")

        XCTAssertEqual(model.tabs.first?.title, "Fixing the shift+enter encoding")
        XCTAssertEqual(recorded, ["a": "Fixing the shift+enter encoding"],
                       "the sidebar/palette can only track a live title if it is handed up")
    }

    func testSwitchingProjectReturnsToItsLastActiveSession() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))

        // Open in tab order, not recency — the switcher must not reshuffle.
        XCTAssertEqual(model.openProjectKeys.map(\.path), ["/p/a", "/p/b"])

        // Last touched in /p/a was a1 (a2 was opened, then a1 refocused).
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.activateProject(Fixture.key("/p/b"))
        XCTAssertEqual(model.activeTab?.sessionID, "b1")

        model.activateProject(Fixture.key("/p/a"))
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a")
        XCTAssertEqual(model.activeTab?.sessionID, "a1", "should return to the last session used there")
    }

    func testProjectCyclingWrapsAndIgnoresASingleProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))

        model.selectNextProject()
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a", "one project: cycling is a no-op")

        model.openSession(Fixture.session("b1", project: "/p/b"))
        model.selectNextProject()
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a", "wraps past the end")
        model.selectPreviousProject()
        XCTAssertEqual(model.activeProjectKey?.path, "/p/b", "wraps past the start")
    }

    func testCloseReturnsToPreviouslyActiveTabNotFirst() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        // From b, open Settings; closing it must land back on b, not a.
        model.openSettings()
        model.closeTab(model.settingsTab!.id)
        XCTAssertEqual(model.activeTab?.sessionID, "b")

        // From b, revisit a, then open c; closing c walks back to a.
        model.activate(model.openTab(forSessionID: "a")!)
        model.openSession(Fixture.session("c", project: "/p/a"))
        model.closeTab(model.openTab(forSessionID: "c")!.id)
        XCTAssertEqual(model.activeTab?.sessionID, "a")
    }

    func testCloseWalksHistoryAcrossProjects() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))
        model.closeTab(model.openTab(forSessionID: "b")!.id)
        // The previous tab lives in another project — return there anyway.
        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a")
    }

    func testCloseTabGracefullyRemovesTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id

        model.closeTab(tabID)   // graceful surface exits synchronously → auto-close

        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testReopenLastClosedTabResumesActivatesAndSpawnsNewSurface() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a", project: "/p/a", title: "Work"))
        let originalTabID = model.tabs[0].id

        model.closeTab(originalTabID)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 1)

        model.reopenLastClosedTab()

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertNotEqual(model.tabs[0].id, originalTabID)
        XCTAssertEqual(model.tabs[0].sessionID, "a")
        XCTAssertEqual(model.tabs[0].title, "Work")
        XCTAssertTrue(model.tabs[0].isResume)
        XCTAssertEqual(model.activeTabID, model.tabs[0].id)
        XCTAssertEqual(factory.created.count, 2)
    }

    func testReopenDuringGracefulCloseKeepsRecordForRetry() {
        // ⌘⇧T can race the close: the record is pushed at closeTab, but a
        // running tab stays in `tabs` until its process exits. Reopening in
        // that window must not spend the record (it once did, silently).
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory, timeout: 60)
        model.openSession(Fixture.session("a", project: "/p/a"))
        factory.created[0].behavior = .hung
        let tabID = model.tabs[0].id

        model.closeTab(tabID)
        XCTAssertEqual(model.tabs.count, 1)   // still draining

        model.reopenLastClosedTab()           // races the close: must no-op
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs[0].id, tabID)

        factory.created[0].simulateExit()     // the close finally lands
        XCTAssertTrue(model.tabs.isEmpty)

        model.reopenLastClosedTab()           // the record survived the race
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs[0].sessionID, "a")
        XCTAssertTrue(model.tabs[0].isResume)
    }

    func testReopenLastClosedTabUsesLIFOOrder() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        let aID = model.openTab(forSessionID: "a")!.id
        let bID = model.openTab(forSessionID: "b")!.id

        model.closeTab(aID)
        model.closeTab(bID)
        model.reopenLastClosedTab()
        XCTAssertEqual(model.activeTab?.sessionID, "b")

        model.reopenLastClosedTab()
        XCTAssertEqual(model.activeTab?.sessionID, "a")
    }

    func testReopenSkipsSessionOpenedAgainAndUsesNextClosedEntry() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        let a = Fixture.session("a", project: "/p/a")
        let b = Fixture.session("b", project: "/p/a")
        model.openSession(a)
        model.openSession(b)
        model.closeTab(model.openTab(forSessionID: "a")!.id)
        model.closeTab(model.openTab(forSessionID: "b")!.id)

        model.openSession(b)
        model.reopenLastClosedTab()

        XCTAssertEqual(Set(model.tabs.compactMap(\.sessionID)), ["a", "b"])
        XCTAssertEqual(model.tabs.filter { $0.sessionID == "b" }.count, 1)
        XCTAssertEqual(model.activeTab?.sessionID, "a")
    }

    func testClosingSettingsDoesNotRecordReopenEntry() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSettings()

        model.closeTab(model.settingsTab!.id)
        model.reopenLastClosedTab()

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 0)
    }

    func testClosingProvisionalTabDoesNotRecordReopenEntry() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let provisional = model.newSession(agent: .codex, project: Fixture.key("/p/a"))
        XCTAssertNil(provisional.sessionID)

        model.closeTab(provisional.id)
        model.reopenLastClosedTab()

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 1)
    }

    func testSelfExitDoesNotRecordReopenEntry() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.earlyExitGraceSeconds = 0
        model.openSession(Fixture.session("a", project: "/p/a"))

        factory.created[0].simulateExit()
        model.reopenLastClosedTab()

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 1)
    }

    func testReopenLastClosedTabSwitchesBackToItsProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))
        model.closeTab(model.openTab(forSessionID: "a")!.id)
        XCTAssertEqual(model.activeProjectKey?.path, "/p/b")

        model.reopenLastClosedTab()

        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a")
    }

    func testConfirmedPendingCloseRecordsReopenEntry() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))

        model.requestClose(tabID: model.tabs[0].id)
        XCTAssertNotNil(model.pendingCloseTabID)
        model.confirmPendingClose()
        model.reopenLastClosedTab()

        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertTrue(model.activeTab?.isResume == true)
    }

    func testProcessSelfExitAutoClosesTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.earlyExitGraceSeconds = 0  // fake exits instantly; simulate a long-lived agent
        model.openSession(Fixture.session("a", project: "/p/a"))
        let fake = model.tabs.first?.surface as? FakeTerminalSurface

        fake?.simulateExit()    // agent quit / crash (ADR-010 reverse)

        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testEarlyExitKeepsTabWithExitedState() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let fake = model.tabs.first?.surface as? FakeTerminalSurface

        fake?.simulateExit(status: 127)  // launch failure right after spawn

        // The tab stays so the error output is readable; the chip shows exited.
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs.first?.activity, .exited(status: 127))

        // Explicitly closing the dead tab removes it.
        model.closeTab(model.tabs.first!.id)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testRequestCloseBusyTabPromptsBeforeRemoving() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id
        XCTAssertEqual(model.tabs.first?.activity, .running)   // agent working

        model.requestClose(tabID: tabID)
        // Gated: nothing closes yet, a confirmation is pending.
        XCTAssertEqual(model.pendingCloseTabID, tabID)
        XCTAssertEqual(model.tabs.count, 1)

        model.confirmPendingClose()
        XCTAssertNil(model.pendingCloseTabID)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testCancelPendingCloseKeepsBusyTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id
        model.requestClose(tabID: tabID)
        XCTAssertEqual(model.pendingCloseTabID, tabID)

        model.cancelPendingClose()
        XCTAssertNil(model.pendingCloseTabID)
        XCTAssertEqual(model.tabs.count, 1)                    // still open
    }

    func testRequestCloseIdleTabClosesImmediately() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.tabs.first!.activity = .idle                     // not working

        model.requestClose(tabID: model.tabs.first!.id)

        XCTAssertNil(model.pendingCloseTabID)                  // no prompt
        XCTAssertTrue(model.tabs.isEmpty)                      // closed right away
    }

    func testRestoreComesBackInLastActiveProject() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        let model = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                      appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))   // last active: /p/b

        let relaunched = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                           appearanceProvider: { .default },
                                           runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                           persistence: persistence)
        relaunched.restore()
        XCTAssertEqual(relaunched.activeProjectKey?.path, "/p/b")
        XCTAssertEqual(relaunched.tabs.count, 3)

        // Switching back by focusing an existing tab also updates the record.
        model.activate(model.tabs.first { $0.sessionID == "a1" }!)
        let again = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                      appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        again.restore()
        XCTAssertEqual(again.activeProjectKey?.path, "/p/a")
    }

    func testRestoreReopensTheTabYouWereLookingAt() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        let model = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                      appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.activate(model.tabs.first { $0.sessionID == "a1" }!)
        model.prepareForQuit()

        let relaunched = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                           appearanceProvider: { .default },
                                           runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                           persistence: persistence)
        relaunched.restore()

        let restoredActive = relaunched.tabs.first { $0.sessionID == "a1" }
        XCTAssertEqual(relaunched.activeTabID, restoredActive?.id, "reopens on the tab you left")
        XCTAssertNotNil(restoredActive?.surface, "the active tab resumes its agent")
        // Lazy restore still holds for everything else: one agent comes back, not all.
        XCTAssertNil(relaunched.tabs.first { $0.sessionID == "a2" }?.surface)
    }

    /// Quitting from the launcher (⌘⇧H, then ⌘Q) is a deliberate "show me nothing"
    /// — restoring a tab over it would override the last thing the user chose.
    func testRestoreShowsLauncherWhenNoTabWasActiveAtQuit() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        let model = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                      appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.showHome()
        model.prepareForQuit()

        let relaunched = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                           appearanceProvider: { .default },
                                           runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                           persistence: persistence)
        relaunched.restore()
        XCTAssertEqual(relaunched.tabs.count, 1, "the chip is still restored")
        XCTAssertNil(relaunched.activeTabID)
        XCTAssertNil(relaunched.tabs.first?.surface, "nothing spawned")
    }

    /// ⌘Q drains every agent, so every surface reports .exited on the way out. If
    /// those exits are treated as agents finishing, quitting closes every tab and
    /// saves an empty set — and the next launch comes back to nothing.
    func testQuitDoesNotErasTheSessionsItMustRestore() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        // Sessions you quit on are long-lived, i.e. well past the early-exit grace
        // that keeps a failed launch visible — so their exits auto-close the tab.
        model.earlyExitGraceSeconds = 0
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))
        XCTAssertEqual(persistence.load().count, 2)

        // Quit: freeze the set, then every draining agent reports its exit.
        model.prepareForQuit()
        for tab in model.tabs {
            guard let surface = tab.surface else { continue }
            model.surface(surface, didChangeState: .exited(status: 0))
        }

        XCTAssertEqual(model.tabs.count, 2, "a drained agent is not a finished agent")
        XCTAssertEqual(Set(persistence.load().map(\.sessionID)), ["a1", "b1"])

        let relaunched = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                           appearanceProvider: { .default },
                                           runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                           persistence: persistence)
        relaunched.restore()
        XCTAssertEqual(Set(relaunched.tabs.compactMap(\.sessionID)), ["a1", "b1"])
    }

    func testClosingInertRestoredChipRemovesWithoutSpawning() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        persistence.save([PersistedTab(sessionID: "a", agent: .claude, projectPath: "/p/a", title: "t")])
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.restore()
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertNil(model.tabs.first?.surface)     // inert
        XCTAssertNil(model.activeTabID)             // launcher shows

        model.closeTab(model.tabs.first!.id)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 0)    // never spawned
    }

    func testNewClaudeSessionKnowsIdImmediately() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        let tab = model.newSession(agent: .claude, project: Fixture.key("/p/a"))
        XCTAssertNotNil(tab.sessionID)
        XCTAssertFalse(tab.isProvisional)
        XCTAssertTrue(tab.displayArgv?.contains("--session-id") ?? false)
    }

    func testNewCodexSessionIsProvisionalThenAdopted() {
        let reconciler = ImmediateReconciler(id: "codex-123")
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory(), reconciler: reconciler)
        let tab = model.newSession(agent: .codex, project: Fixture.key("/p/a"))
        // ImmediateReconciler adopts synchronously.
        XCTAssertEqual(tab.sessionID, "codex-123")
        XCTAssertFalse(tab.isProvisional)
    }

    func testDefaultAgentNewSessionUsesConfiguredAgent() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory(), defaultAgent: .codex)
        model.openSession(Fixture.session("a", project: "/p/a"))  // set active project
        let tab = model.newSessionDefaultAgent()
        XCTAssertEqual(tab?.agent, .codex)
    }

    func testSettingsTabIsSingletonAndProjectAgnostic() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSettings()
        model.openSettings()
        XCTAssertEqual(model.tabs.filter { $0.kind == .settings }.count, 1)
        // Settings appears in the bar regardless of active project.
        XCTAssertTrue(model.visibleTabs.contains { $0.kind == .settings })
    }

    func testSelectTabByIndexWithinProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.selectTab(index: 1)
        XCTAssertEqual(model.activeTab?.sessionID, "a1")
        model.selectTab(index: 2)
        XCTAssertEqual(model.activeTab?.sessionID, "a2")
    }

    func testMoveTabReordersWithinProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
        model.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a2", "a1"])
    }

    func testSettingsTabDefaultsToTrailingInVisibleRow() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Default offset keeps Settings at the end (matches original behavior).
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .session, .settings])
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
    }

    func testMoveSettingsTabToMiddleReorders() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Row is [a1, a2, Settings]; drag Settings (index 2) to the middle (index 1).
        model.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .settings, .session])
        // Session order is untouched.
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
    }

    func testMoveTabToFrontAndToEnd() {
        // The chip menu's restacking controls: front = toOffset 0, end =
        // toOffset row-count, from any middle position — Settings included.
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        model.openSession(Fixture.session("c", project: "/p/a"))
        model.openSettings()   // [a, b, c, Settings]

        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: 0)   // b to front
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["b", "a", "c"])

        let count = model.visibleTabs.count
        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: count)   // a to end
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["b", "c", "a"])
        // a passed Settings on its way to the end; Settings stepped aside.
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .session, .settings, .session])
    }

    func testSessionCrossesSettingsInOneStep() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Put Settings in the middle: [a1, Settings, a2].
        model.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        // The drag gesture swaps one slot at a time: a1 crossing Settings is
        // the adjacent exchange move(0 → 2). Settings must step aside — the
        // old pinned-offset behavior reconstructed the identical row and the
        // drag could never pass the Settings chip.
        model.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.settings, .session, .session])
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])

        // The next step exchanges a1 with a2; Settings keeps its new slot.
        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.settings, .session, .session])
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a2", "a1"])
    }

    func testSettingsOffsetIsGlobalAndClampsAcrossProjects() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))
        model.openSettings()
        // Active project is /p/b (1 session). Row is [b1, Settings]; move Settings to front.
        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.settings, .session])

        // Switch back to /p/a (2 sessions): offset 0 is preserved (global, clamped).
        model.openSession(Fixture.session("a1", project: "/p/a"))
        XCTAssertEqual(model.activeProjectKey?.path, "/p/a")
        XCTAssertEqual(model.visibleTabs.first?.kind, .settings)
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
    }

    func testRestoreBuildsInertChips() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        persistence.save([
            PersistedTab(sessionID: "a", agent: .claude, projectPath: "/p/a", title: "A"),
            PersistedTab(sessionID: "b", agent: .codex, projectPath: "/p/a", title: "B"),
        ])
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.restore()
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertTrue(model.tabs.allSatisfy { $0.surface == nil })
        XCTAssertEqual(factory.created.count, 0)   // no process storm
    }

    func testDBPersistenceReopensAndRestoresFullInertTabMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("temple.sqlite")
        let writer = DBTabPersistence(db: try TempleDB(path: path))
        writer.save([
            PersistedTab(sessionID: "claude-id", agent: .claude,
                         projectPath: "/p/a", title: "Claude title"),
            PersistedTab(sessionID: "codex-id", agent: .codex,
                         projectPath: "/p/a", title: "Codex title"),
        ])

        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(
            surfaceFactory: factory,
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(),
            registry: InMemoryProcessRegistry(),
            persistence: DBTabPersistence(db: try TempleDB(path: path))
        )
        model.restore()

        XCTAssertEqual(model.tabs.compactMap(\.sessionID), ["claude-id", "codex-id"])
        XCTAssertEqual(model.tabs.map(\.agent), [.claude, .codex])
        XCTAssertEqual(model.tabs.map(\.title), ["Claude title", "Codex title"])
        XCTAssertTrue(model.tabs.allSatisfy { $0.surface == nil })
        XCTAssertEqual(factory.created.count, 0)
    }

    /// The launch-failure header shows the argv the tab launched with, so its "is the
    /// command to blame?" verdict must be frozen when the tab dies. Re-deriving it from
    /// today's settings lets an unrelated edit rewrite history: break your arguments an
    /// hour later and a healthy old failure suddenly gets blamed for it.
    func testLaunchBlameIsFrozenWhenTheTabDies() {
        var toolchainHealthy = true
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in LocalHostLauncher(binaryPath: { _ in "/bin/claude" },
                availability: { _ in toolchainHealthy ? .available : .unavailable(reason: "doesn't run") }, folderEvidence: { _ in .unknown }) })

        let tab = model.newSession(agent: .claude, project: Fixture.key("/p/a"))
        let surface = tab.surface as? FakeTerminalSurface
        surface?.simulateExit(status: 1)                 // dies while the toolchain is fine

        XCTAssertFalse(tab.commandWasSuspect, "a verified command was blamed")

        // The user later breaks their settings. The dead tab's verdict must not move.
        toolchainHealthy = false
        XCTAssertFalse(tab.commandWasSuspect, "an old failure was re-judged by new settings")
    }

    func testATabThatDiesWithABrokenToolchainDoesBlameTheCommand() {
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in LocalHostLauncher(binaryPath: { _ in "/bin/claude" },
                availability: { _ in .unavailable(reason: "not found") }, folderEvidence: { _ in .unknown }) })

        let tab = model.newSession(agent: .claude, project: Fixture.key("/p/a"))
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertTrue(tab.commandWasSuspect)
    }

    private func modelForResumeTests(sessionKnown: @escaping (String) -> Bool?,
                                     directoryEvidence: @escaping (ProjectKey) -> DirectoryEvidence = { _ in .unknown }) -> OpenSessionsModel {
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in LocalHostLauncher(binaryPath: { _ in "/bin/claude" }, folderEvidence: { _ in .unknown }) },
            directoryEvidence: directoryEvidence)
        model.sessionKnown = sessionKnown
        return model
    }

    /// A gone folder is not started somewhere else (the terminal would keep
    /// Temple's cwd); the header says why, and a click after the folder is
    /// back starts it.
    func testAMissingFolderIsNotSpawnedAndARestoredOneIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = FakeTerminalSurfaceFactory()
        // This Mac's launcher, which proves a folder gone from its own stat.
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in LocalHostLauncher() },
            directoryEvidence: Fixture.localDirectoryEvidence)
        var recorded: [String] = []
        model.launchDirectoryHandler = { _, _, path in recorded.append(path) }
        var joined: [String] = []
        model.openedHandler = { open in joined.append(open.id); return .joined }
        model.openSession(Fixture.session("gone", project: directory.path))
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertTrue(factory.created.isEmpty, "nothing runs in Temple's own cwd instead")
        XCTAssertEqual(tab.launchPreparationError, "The folder \(directory.path) no longer exists.")
        XCTAssertEqual(tab.activity, .exited(status: -1))
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(joined.isEmpty)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.activate(tab)
        XCTAssertEqual(factory.created.count, 1)
        XCTAssertNil(tab.launchPreparationError)
        XCTAssertEqual(tab.activity, .running)
        model.drainLaunchResults()
        XCTAssertEqual(recorded, [directory.path])
    }

    func testAnEarlyExitingResumeWithAMissingTargetGetsAnnotated() {
        // Index loaded, and no transcript on disk carries this id (the id
        // rotated out from under the tab via in-session /resume or /clear).
        let model = modelForResumeTests(sessionKnown: { _ in false })

        model.openSession(Fixture.session("gone", project: "/p/a"))  // resume of an indexed session
        let tab = model.activeTab!
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertTrue(tab.resumeTargetMissing)
        XCTAssertFalse(tab.commandWasSuspect, "a healthy command must not be blamed too")
    }

    func testAnUnloadedIndexNeverClaimsAMissingResumeTarget() {
        let model = modelForResumeTests(sessionKnown: { _ in nil })  // index loading: unknown, not missing

        model.openSession(Fixture.session("gone", project: "/p/a"))
        let tab = model.activeTab!
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertFalse(tab.resumeTargetMissing)
    }

    func testANewSessionEarlyExitIsNeverBlamedOnIdRotation() {
        // A NEW tab's freshly minted id is legitimately absent from the index;
        // its early exit (auth, config, anything) is not a resume failure.
        let model = modelForResumeTests(sessionKnown: { _ in false })

        let tab = model.newSession(agent: .claude, project: Fixture.key("/p/a"))
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertFalse(tab.resumeTargetMissing)
    }

    func testExtraArgsAreInsertedAfterBinaryForNewAndResume() {
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in LocalHostLauncher(binaryPath: { $0 == .codex ? "/bin/codex" : "/bin/claude" },
                extraArgs: { $0 == .codex ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--dangerously-skip-permissions"] }, folderEvidence: { _ in .unknown }) })

        let tab = model.newSession(agent: .claude, project: Fixture.key("/p/a"))
        XCTAssertEqual(tab.displayArgv?.prefix(2).map { $0 },
                       ["/bin/claude", "--dangerously-skip-permissions"])

        model.openSession(Fixture.session("r1", agent: .codex, project: "/p/b"))
        let resumed = model.tabs.first { $0.sessionID == "r1" }
        // Flags precede the subcommand: codex <flags> resume <id>.
        XCTAssertEqual(resumed?.displayArgv,
                       ["/bin/codex", "--dangerously-bypass-approvals-and-sandbox", "resume", "r1"])
    }
}

@MainActor
final class ImmediateReconciler: TempleUI.CodexAdopting {
    let id: String
    init(id: String) { self.id = id }
    func reconcile(host: HostID, projectPath: String, startedAt: Date, adopt: @escaping (String, TranscriptLocator?) -> Void) {
        adopt(id, nil)
    }
}

@MainActor
private final class ObservingLauncher: HostLauncher {
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        let argv = spec.agent.resumeArgv(sessionID: "x")
        return AgentLaunch(command: TerminalCommand(argv: argv, cwd: spec.directory,
                                                    env: ["IDENTITY_AT_WRAP": "absent"]),
                           displayArgv: argv, result: nil)
    }
    func availability(_ agent: Agent) -> LaunchAvailability { .available }
}

@MainActor
private final class CountingLauncher: HostLauncher {
    private let inner = LocalHostLauncher(folderEvidence: { _ in .unknown })
    private(set) var count = 0
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        count += 1
        return try inner.prepare(spec)
    }
    func availability(_ agent: Agent) -> LaunchAvailability { .available }
}
