import XCTest
@testable import TempleUI
import TempleCore

/// History at scale (perf plan §6, the UI side): the projection runs off the
/// main actor, the main actor only installs snapshots, an unchanged
/// projection publishes nothing, superseded work never lands, and 10,000
/// rows project and search inside generous bounds. Work counts are asserted
/// exactly; timings only against thresholds far above the targets, so a slow
/// runner does not fail them. `HISTORY_PERF=1` prints the measurements.
@MainActor
final class HistoryPerfTests: XCTestCase {
    private static func rows(_ count: Int, base: Date = Date()) -> [TranscriptSummary] {
        (0..<count).map { i in
            TranscriptSummary(id: "s-\(i)", agent: i % 2 == 0 ? .claude : .codex,
                locator: TranscriptLocator(localURL: URL(fileURLWithPath: "/tmp/s-\(i).jsonl")),
                modifiedAt: base.addingTimeInterval(-Double(i) * 600), cwd: "/Users/me/Projects/p\(i % 50)",
                firstPrompt: "Investigate the history page optimization number \(i) and report what changed",
                gitBranch: "feature/\(i % 7)", model: "model-x", messageCount: i % 90,
                lastMessagePreview: "The last message for session \(i) talks about scrolling and layout in some detail.")
        }
    }

    private struct Loaded {
        let history: HistoryModel
        let loadSeconds: TimeInterval
        let maxStall: TimeInterval
        let totalStall: TimeInterval
    }

    /// Feeds `count` rows in batches of 200, as the catalog does, and waits
    /// for the page to have them all.
    private func load(_ count: Int) async throws -> Loaded {
        let rows = Self.rows(count)
        let batches = stride(from: 0, to: rows.count, by: 200).map { Array(rows[$0..<min($0 + 200, rows.count)]) }
        let history = HistoryModel(overlay: SessionOverlayStore(db: try TempleDB.inMemory()), catalog: {
            AsyncStream { continuation in
                for (index, batch) in batches.enumerated() {
                    continuation.yield(HostCatalogEvent(host: .local,
                        batch: .sessions(batch, read: (index + 1) * 200, total: count)))
                }
                continuation.finish()
            }
        }, pathExists: { _ in true })
        let beat = MainStallMeter()
        let started = Date()
        history.activate()
        while history.readState != .done { try await Task.sleep(nanoseconds: 2_000_000) }
        await history.settle()
        let seconds = Date().timeIntervalSince(started)
        let (maxStall, totalStall) = beat.stop()
        XCTAssertEqual(history.allRows.count, count)
        history.deactivate()
        return Loaded(history: history, loadSeconds: seconds, maxStall: maxStall, totalStall: totalStall)
    }

    /// The projection runs on its own actor, never the main thread; the
    /// main actor's share is the install, and catalog batches coalesce into
    /// fewer installs than there were batches.
    func testTenThousandRowsProjectOffTheMainActorAndInstallCheaply() async throws {
        for count in [2_000, 10_000] {
            let loaded = try await load(count)
            let history = loaded.history
            let stats = await history.projector.stats
            XCTAssertFalse(stats.ranOnMainThread, "the projection never runs on the main thread")
            XCTAssertGreaterThan(stats.merges + stats.fullSorts, 0, "the sorting happened, off the main actor")
            XCTAssertLessThan(history.rebuildCount, count / 200 + 2, "batches after the first coalesce")
            let installs = history.installDurations
            let worstInstall = installs.max() ?? 0
            XCTAssertLessThan(worstInstall, 0.05, "an install is an assignment and a selection check")

            // Search: the worker filters and groups; the main actor installs.
            var searchLatency: [String: TimeInterval] = [:]
            var searchWork: [String: TimeInterval] = [:]
            for needle in ["optimization number 42", "no-result-needle", ""] {
                let started = Date()
                history.query = needle
                await history.settle()
                searchLatency[needle] = Date().timeIntervalSince(started)
                searchWork[needle] = await history.projector.stats.lastDuration
            }
            XCTAssertEqual(history.query, "")
            XCTAssertEqual(history.visibleRows.count, count)
            XCTAssertLessThan(searchLatency.values.max() ?? 0, 2.0, "generous: the target is 100 ms in the worker")
            if ProcessInfo.processInfo.environment["HISTORY_PERF"] == "1" {
                func ms(_ t: TimeInterval) -> String { String(format: "%.1f", t * 1000) }
                print("HISTORY-PERF rows=\(count) load_ms=\(ms(loaded.loadSeconds)) installs=\(history.rebuildCount)"
                      + " install_max_ms=\(ms(worstInstall)) install_total_ms=\(ms(installs.reduce(0, +)))"
                      + " main_stall_max_ms=\(ms(loaded.maxStall)) main_stall_total_over_8ms=\(ms(loaded.totalStall))"
                      + " search_match_ms=\(ms(searchLatency["optimization number 42"]!)) (worker \(ms(searchWork["optimization number 42"]!)))"
                      + " search_none_ms=\(ms(searchLatency["no-result-needle"]!)) (worker \(ms(searchWork["no-result-needle"]!)))"
                      + " search_clear_ms=\(ms(searchLatency[""]!)) (worker \(ms(searchWork[""]!)))")
            }
        }
    }

    /// The same input twice: the second projection changes nothing, so it
    /// publishes nothing and nothing is installed.
    func testAnUnchangedProjectionPublishesNothing() async throws {
        let projector = HistoryProjector()
        let rows = Self.rows(300)
        let input = HistoryProjectionInput(catalog: [.upsert(rows, noise: [], folders: [:])], members: [])
        let first = await projector.apply(input)
        XCTAssertEqual(first?.allRows.count, 300)
        let again = await projector.apply(input)
        XCTAssertNil(again, "the same rows again: nothing to publish")
        let membersOnly = await projector.apply(HistoryProjectionInput(members: []))
        XCTAssertNil(membersOnly)
        let published = await projector.stats.published
        XCTAssertEqual(published, 1)
    }

    /// A snapshot built for a query the page has since moved past never
    /// lands: the newer one does.
    func testAStaleGenerationNeverLands() async throws {
        let history = HistoryModel(overlay: SessionOverlayStore(db: try TempleDB.inMemory()), catalog: {
            AsyncStream { continuation in
                continuation.yield(HostCatalogEvent(host: .local, batch: .sessions(Self.rows(50), read: 50, total: 50)))
                continuation.finish()
            }
        }, pathExists: { _ in true })
        history.activate()
        while history.readState != .done { try await Task.sleep(nanoseconds: 2_000_000) }
        await history.settle()

        // Hold the next projection between its return and its install.
        var held: CheckedContinuation<Void, Never>?
        var holding = true
        history.beforeInstall = {
            guard holding else { return }
            await withCheckedContinuation { held = $0 }
        }
        history.query = "number 1"
        let stale = history.generation
        while held == nil { await Task.yield() }
        history.query = "number 2"
        holding = false
        held?.resume()
        await history.settle()

        XCTAssertFalse(history.installedGenerations.contains(stale), "built for a query since replaced")
        XCTAssertEqual(history.installedGenerations.last, history.generation)
        XCTAssertEqual(history.snapshot.query.search, "number 2")
        XCTAssertTrue(history.visibleRows.allSatisfy { $0.title.contains("number 2") })
        history.deactivate()
    }
}

/// Backpressure and re-formatting.
@MainActor
final class HistoryBackpressureTests: XCTestCase {
    private final class Pulls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// While the page cannot take more (its projection held), the rows
    /// handed to it and not yet taken stay within its bound: the lane waits.
    /// Once it can, every row arrives. Bounded on History's side, lossless.
    func testThePagesBacklogStaysBoundedWhileItIsBehindAndLosesNothing() async throws {
        let pulls = Pulls()
        let rows = (0..<10_000).map { i in
            TranscriptSummary(id: "s-\(i)", agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/s-\(i)"),
                              modifiedAt: Date(timeIntervalSince1970: Double(100_000 - i)), cwd: "/p", firstPrompt: "Row \(i)")
        }
        let history = HistoryModel(overlay: SessionOverlayStore(db: try TempleDB.inMemory()), catalog: {
            AsyncStream(unfolding: {
                let i = pulls.next()
                guard i < 100 else { return nil }
                return HostCatalogEvent(host: .local, batch: .sessions(Array(rows[(i * 100)..<((i + 1) * 100)]),
                                                                       read: (i + 1) * 100, total: 10_000))
            })
        }, pathExists: { _ in true })
        history.catalogBacklogLimit = 300
        var held: CheckedContinuation<Void, Never>?
        var holding = true
        history.beforeInstall = {
            guard holding else { return }
            await withCheckedContinuation { held = $0 }
        }

        history.activate()
        while held == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThanOrEqual(history.catalogBacklog, 300 + 100, "the bound, plus the batch that crossed it")
        XCTAssertGreaterThanOrEqual(history.catalogBacklog, 300, "the lane waits at the bound")
        if case .reading(let read, _) = history.readState {
            XCTAssertLessThanOrEqual(read, 500, "the lane stopped delivering")
        }

        holding = false
        held?.resume()
        while history.readState != .done { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(history.allRows.count, 10_000, "nothing dropped")
        history.deactivate()
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }

    /// A new day re-titles an idle page ("Today" becomes "Yesterday"), and a
    /// new time zone or locale rebuilds its calendar and formatters, with no
    /// other input arriving.
    func testDayTimeZoneAndLocaleChangesReformatAnIdlePage() async throws {
        let center = NotificationCenter()
        let clock = Clock(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!)
        let row = TranscriptSummary(id: "a", agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/a"),
                                    modifiedAt: clock.now.addingTimeInterval(-3600), cwd: "/p", firstPrompt: "A")
        let history = HistoryModel(overlay: SessionOverlayStore(db: try TempleDB.inMemory()), catalog: {
            AsyncStream { $0.yield(HostCatalogEvent(host: .local, batch: .sessions([row], read: 1, total: 1))); $0.finish() }
        }, pathExists: { _ in true }, now: { clock.now }, notificationCenter: center)
        history.activate()
        while history.readState != .done { try await Task.sleep(nanoseconds: 2_000_000) }
        await history.settle()
        XCTAssertEqual(history.groups.map(\.title), ["Today"])
        let builders = await history.projector.builderGeneration

        clock.advance(24 * 3600)
        center.post(name: .NSCalendarDayChanged, object: nil)
        await history.settle()
        XCTAssertEqual(history.groups.map(\.title), ["Yesterday"])

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await history.settle()
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        await history.settle()
        let rebuilt = await history.projector.builderGeneration
        XCTAssertEqual(rebuilt, builders + 3, "a fresh calendar and formatters each time")
        history.deactivate()
    }
}

/// Main-queue ticks every millisecond; a gap is time the main thread was busy.
@MainActor
final class MainStallMeter {
    private var last = DispatchTime.now()
    private var worst: TimeInterval = 0
    private var stalls: TimeInterval = 0
    private let timer = DispatchSource.makeTimerSource(queue: .main)

    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                let now = DispatchTime.now()
                let gap = TimeInterval(now.uptimeNanoseconds - self.last.uptimeNanoseconds) / 1e9
                self.last = now
                self.worst = max(self.worst, gap)
                if gap > 0.008 { self.stalls += gap }
            }
        }
        timer.resume()
    }

    /// The longest gap, and the sum of gaps over 8 ms.
    func stop() -> (TimeInterval, TimeInterval) {
        timer.cancel()
        return (worst, stalls)
    }
}
