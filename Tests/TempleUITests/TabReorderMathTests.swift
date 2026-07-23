import XCTest
import CoreGraphics
@testable import TempleUI

/// Chrome's rule: the dragged chip (virtual frame, glued to the hand) takes a
/// neighbor's slot the moment its edge crosses that neighbor's center.
/// Scenario: 200pt chips at [0,200) [200,400) [400,600); dragging the middle
/// one, so left neighbor mid = 100, right neighbor mid = 500.
final class TabReorderMathTests: XCTestCase {
    func testSwapRightWhenTrailingEdgeCrossesNeighborMid() {
        XCTAssertEqual(TabReorderMath.step(chipMin: 299, chipMax: 499,
                                           leftNeighborMidX: 100, rightNeighborMidX: 500), 0)
        XCTAssertEqual(TabReorderMath.step(chipMin: 301, chipMax: 501,
                                           leftNeighborMidX: 100, rightNeighborMidX: 500), 1)
    }

    func testSwapLeftWhenLeadingEdgeCrossesNeighborMid() {
        XCTAssertEqual(TabReorderMath.step(chipMin: 101, chipMax: 301,
                                           leftNeighborMidX: 100, rightNeighborMidX: 500), 0)
        XCTAssertEqual(TabReorderMath.step(chipMin: 99, chipMax: 299,
                                           leftNeighborMidX: 100, rightNeighborMidX: 500), -1)
    }

    /// After an equal-width swap the same chip position must hold still — no
    /// oscillation. Post-right-swap the neighbors' mids become 300-width
    /// apart: old right neighbor now sits left at mid 300, next right at 700.
    func testStableAfterSwapAtSamePosition() {
        XCTAssertEqual(TabReorderMath.step(chipMin: 301, chipMax: 501,
                                           leftNeighborMidX: 100, rightNeighborMidX: 500), 1)
        XCTAssertEqual(TabReorderMath.step(chipMin: 301, chipMax: 501,
                                           leftNeighborMidX: 300, rightNeighborMidX: 700), 0)
    }

    /// Row ends: a missing neighbor never moves the chip past the edge.
    func testEndsClamp() {
        XCTAssertEqual(TabReorderMath.step(chipMin: -400, chipMax: -200,
                                           leftNeighborMidX: nil, rightNeighborMidX: 300), 0)
        XCTAssertEqual(TabReorderMath.step(chipMin: 900, chipMax: 1100,
                                           leftNeighborMidX: 300, rightNeighborMidX: nil), 0)
    }

    /// The right check wins when both edges are past both neighbors (a fast
    /// sweep between ticks): one step at a time, direction of travel first.
    func testOneStepPerTick() {
        XCTAssertEqual(TabReorderMath.step(chipMin: 550, chipMax: 750,
                                           leftNeighborMidX: 100, rightNeighborMidX: 500), 1)
    }

    /// Unequal widths (the natural-width Settings chip) use the neighbor's
    /// real center — a narrow neighbor swaps sooner.
    func testUnequalNeighborWidths() {
        // Settings chip on the right at [400,480), mid 440.
        XCTAssertEqual(TabReorderMath.step(chipMin: 239, chipMax: 439,
                                           leftNeighborMidX: 100, rightNeighborMidX: 440), 0)
        XCTAssertEqual(TabReorderMath.step(chipMin: 241, chipMax: 441,
                                           leftNeighborMidX: 100, rightNeighborMidX: 440), 1)
    }
}
