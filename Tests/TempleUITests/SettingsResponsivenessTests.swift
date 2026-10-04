import Combine
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore

/// Typing in Settings must not re-tint terminals or re-render the window.
/// Every settings change used to re-apply the terminal appearance — a config
/// rewrite pushed to every open terminal — and republish `AppModel`, so each
/// key typed in an agent's Command field lagged behind with tabs open.
@MainActor
final class SettingsResponsivenessTests: XCTestCase {
    private var factory: FakeTerminalSurfaceFactory!
    private var model: AppModel!
    private var republished = 0
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        factory = FakeTerminalSurfaceFactory()
        model = AppModel(surfaceFactory: factory,
                         engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                         database: try TempleDB.inMemory(),
                         settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                         hostRegistry: Fixture.hostsWithoutFolderEvidence())
        _ = model.openSessions.newSession(agent: .claude, projectPath: "/p/a")
        _ = model.openSessions.newSession(agent: .codex, projectPath: "/p/b")
        model.objectWillChange.sink { [weak self] in self?.republished += 1 }.store(in: &cancellables)
        await settle()
    }

    private var applied: Int { factory.created.reduce(0) { $0 + $1.appliedAppearances.count } }

    private func settle(_ ms: Int = 50) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    func testTypingACommandOrArgumentsTouchesNoTerminalAndNoWindow() async {
        let before = (applied, republished)
        for prefix in ["/", "/o", "/op", "/opt", "/opt/claude"] {
            model.settings.setOverridePath(prefix, for: .claude)
            model.settings.setExtraArgsText("--model" + prefix, for: .codex)
        }
        await settle(500)
        XCTAssertEqual(applied, before.0, "a Command/Arguments keystroke re-applied the terminal appearance")
        XCTAssertEqual(republished, before.1, "a Command/Arguments keystroke re-rendered the whole window")
    }

    func testFontSizeAndThemeStillApplyLiveToEveryTerminal() async {
        let before = applied
        model.settings.fontSize = model.settings.fontSize + 1
        await settle()
        XCTAssertEqual(applied, before + 2, "each open terminal gets the new font size")
        XCTAssertEqual(factory.created.last?.appliedAppearances.last?.fontSize, model.settings.fontSize)
        model.settings.theme = model.settings.theme == .dark ? .light : .dark
        await settle()
        XCTAssertEqual(applied, before + 4)
    }

    func testFontFamilyAppliesOnceTypingPauses() async {
        let before = applied
        for prefix in ["M", "Me", "Men", "Menl", "Menlo"] {
            model.settings.fontFamily = prefix
            await settle(30)
        }
        XCTAssertEqual(applied, before, "a half-typed family name reached the terminals")
        await settle(600)
        XCTAssertEqual(applied, before + 2, "the finished name applies once per terminal")
        XCTAssertEqual(factory.created.last?.appliedAppearances.last?.fontFamily, "Menlo")
    }

    /// The page's own fields hold a draft: typing in any of them reaches
    /// neither the store nor the terminals; Return/blur commits once.
    func testDraftsTouchNothingUntilCommittedAndThenApplyOnce() async {
        let editor = SettingsEditor(store: model.settings, toolchain: model.toolchain)
        var drafts = SettingsDrafts()
        // The bindings the page's fields are given: a keystroke is a set.
        let state = Binding(get: { drafts }, set: { drafts = $0 })
        let family = editor.binding(.fontFamily, drafts: state)
        let command = editor.binding(.command(.claude), drafts: state)
        let arguments = editor.binding(.arguments(.codex), drafts: state)
        let before = (applied, republished)
        for prefix in ["M", "Me", "Men", "Menl", "Menlo"] {
            family.wrappedValue = prefix
            command.wrappedValue = "/nonexistent/" + prefix
            arguments.wrappedValue = "--" + prefix
            await settle(30)
        }
        XCTAssertEqual(family.wrappedValue, "Menlo", "the field shows the draft")
        await settle(600)
        XCTAssertEqual(applied, before.0, "a draft keystroke reached the terminals")
        XCTAssertEqual(republished, before.1, "a draft keystroke re-rendered the window")
        XCTAssertEqual(model.settings.fontFamily, "", "a draft reached the store")
        XCTAssertEqual(model.settings.claudePath, "")

        editor.commit(.fontFamily, drafts: &drafts)
        await settle(600)
        XCTAssertEqual(applied, before.0 + 2, "the committed family applies once per terminal")
        XCTAssertEqual(factory.created.last?.appliedAppearances.last?.fontFamily, "Menlo")

        // Committing a command or arguments re-checks the toolchain; it never
        // re-applies the terminal appearance.
        let afterFamily = applied
        editor.commit(.command(.claude), drafts: &drafts)
        editor.commit(.arguments(.codex), drafts: &drafts)
        XCTAssertTrue(model.toolchain.isCheckingUserSettings)
        await settle(500)
        XCTAssertEqual(applied, afterFamily)
        XCTAssertEqual(model.settings.claudePath, "/nonexistent/Menlo")
    }

    func testDefaultAgentStillRepublishesForTheViewsThatShowIt() async {
        let before = republished
        model.settings.defaultAgent = model.settings.defaultAgent == .claude ? .codex : .claude
        await settle()
        XCTAssertGreaterThan(republished, before)
    }
}
