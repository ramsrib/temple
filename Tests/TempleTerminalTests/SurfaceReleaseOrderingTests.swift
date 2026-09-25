import XCTest
import GhosttyKit
@testable import TempleTerminal

/// The address-reuse race: a surface freed inside a libghostty callback, then a
/// successor spawned at the same address, inherits the freed surface's queued
/// messages. `GhosttyApp.release` must therefore never free inside a tick, and
/// must drain right after every free. Pinned with the free/drain seams so no
/// real surface is needed; the live runtime is covered by GhosttyRuntimeTests.
@MainActor
final class SurfaceReleaseOrderingTests: XCTestCase {
    private enum Event: Equatable { case freed(Int), drained, spawned(Int) }

    private var events: [Event] = []
    private var app: GhosttyApp { GhosttyApp.shared }

    override func setUp() {
        super.setUp()
        events = []
        app.freeSurface = { [weak self] s in self?.events.append(.freed(Int(bitPattern: s))) }
        app.drainMailbox = { [weak self] in self?.events.append(.drained) }
    }

    override func tearDown() {
        app.freeSurface = { ghostty_surface_free($0) }
        app.drainMailbox = { [weak app = GhosttyApp.shared] in
            guard let app, let handle = app.app else { return }
            ghostty_app_tick(handle)
        }
        super.tearDown()
    }

    private func fake(_ n: Int) -> ghostty_surface_t { UnsafeMutableRawPointer(bitPattern: n)! }

    func testReleaseOutsideATickFreesThenDrainsImmediately() {
        app.release(fake(1), keeping: nil)
        XCTAssertEqual(events, [.freed(1), .drained])
    }

    func testReleaseInsideATickWaitsForTheTickToEnd() {
        var duringTick: [Event] = []
        app.runTick {
            self.app.release(self.fake(1), keeping: nil)
            duringTick = self.events
        }
        // Nothing freed while the tick's callbacks could still spawn.
        XCTAssertEqual(duringTick, [])
        // Freed and drained before runTick returned — before any caller
        // further up could spawn at the freed address.
        XCTAssertEqual(events, [.freed(1), .drained])
    }

    func testAReleaseFromTheDrainItselfGetsItsOwnFreeAndDrain() {
        // The drain's callbacks (a close-surface for another tab) release too;
        // each round must free before it drains again.
        var rounds = 0
        app.drainMailbox = { [weak self] in
            guard let self else { return }
            self.events.append(.drained)
            rounds += 1
            if rounds == 1 { self.app.release(self.fake(2), keeping: nil) }
        }
        app.release(fake(1), keeping: nil)
        XCTAssertEqual(events, [.freed(1), .drained, .freed(2), .drained])
        XCTAssertFalse(app.isTicking)
    }

    func testTickDoesNotReenter() {
        var depth = 0, maxDepth = 0
        app.drainMailbox = { [weak self] in
            guard let self else { return }
            depth += 1; maxDepth = max(maxDepth, depth)
            self.app.tick()   // a wakeup landing mid-drain must not nest
            depth -= 1
        }
        app.tick()
        XCTAssertEqual(maxDepth, 1)
    }

    // MARK: Spawns wait for the drain

    func testSpawnOutsideATickRunsAtOnce() {
        var wasDeferred: Bool?
        let ranNow = app.spawn { [weak self] deferred in
            wasDeferred = deferred
            self?.events.append(.spawned(1))
        }
        XCTAssertTrue(ranNow)
        XCTAssertEqual(wasDeferred, false)
        XCTAssertEqual(events, [.spawned(1)])
    }

    func testSpawnInsideATickRunsAfterTheTicksReleasesAreFreedAndDrained() {
        app.runTick {
            // The order a child-exited callback produces: the closing tab
            // releases, then its neighbour is selected and spawned.
            self.app.release(self.fake(1), keeping: nil)
            let ranNow = self.app.spawn { [weak self] deferred in
                XCTAssertTrue(deferred)
                self?.events.append(.spawned(2))
            }
            XCTAssertFalse(ranNow)
        }
        XCTAssertEqual(events, [.freed(1), .drained, .spawned(2)])
    }

    func testSpawnRequestedByTheDrainWaitsForTheDrain() {
        // A release outside a tick drains at once; that drain's callbacks
        // close another tab and spawn its neighbour. The spawn must not take
        // the just-freed address before the drain has dropped its leftovers.
        app.drainMailbox = { [weak self] in
            guard let self else { return }
            self.events.append(.drained)
            self.app.spawn { [weak self] _ in self?.events.append(.spawned(2)) }
        }
        app.release(fake(1), keeping: nil)
        XCTAssertEqual(events, [.freed(1), .drained, .spawned(2)])
        XCTAssertFalse(app.isTicking)
    }

    // MARK: The owner outlives the surface

    private final class Owner {}

    func testOwnerIsRetainedUntilTheSurfaceIsFreed() {
        weak var weakOwner: Owner?
        var aliveAtFree = false
        app.freeSurface = { _ in aliveAtFree = weakOwner != nil }
        app.runTick {
            let owner = Owner()
            weakOwner = owner
            self.app.release(self.fake(1), keeping: owner)
            // `owner` goes out of scope here; the runtime must hold it.
        }
        XCTAssertTrue(aliveAtFree, "libghostty can still call back into the owner until the free")
        XCTAssertNil(weakOwner, "and nothing keeps it after")
    }
}
