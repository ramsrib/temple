import XCTest
@testable import TempleUI

final class TabReorderMathTests: XCTestCase {
    private let equalMidpoints: [CGFloat] = [50, 150, 250, 350]

    func testAdjacentSwapRight() {
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: 151, midXs: equalMidpoints, from: 0), 2)
    }

    func testAdjacentSwapLeft() {
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: 149, midXs: equalMidpoints, from: 2), 1)
    }

    func testNoOpWithinOwnSlotAndAdjacentHalf() {
        XCTAssertNil(TabReorderMath.insertionOffset(
            x: 125, midXs: equalMidpoints, from: 1))
        XCTAssertNil(TabReorderMath.insertionOffset(
            x: 225, midXs: equalMidpoints, from: 1))
    }

    func testDragToBothEnds() {
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: -1, midXs: equalMidpoints, from: 3), 0)
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: 401, midXs: equalMidpoints, from: 0), 4)
    }

    func testRepeatedTickIsIdempotentAfterMove() {
        let x: CGFloat = 251
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: x, midXs: equalMidpoints, from: 0), 3)
        XCTAssertNil(TabReorderMath.insertionOffset(
            x: x, midXs: equalMidpoints, from: 2))
    }

    func testUnequalWidthsUseActualMidpoints() {
        let midpoints: [CGFloat] = [100, 302, 356]
        XCTAssertNil(TabReorderMath.insertionOffset(
            x: 330, midXs: midpoints, from: 1))
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: 357, midXs: midpoints, from: 1), 3)
    }

    func testFromAtEachEnd() {
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: 151, midXs: equalMidpoints, from: 0), 2)
        XCTAssertEqual(TabReorderMath.insertionOffset(
            x: 249, midXs: equalMidpoints, from: 3), 2)
    }
}
