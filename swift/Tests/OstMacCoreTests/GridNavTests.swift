// GridNavTests.swift — om-a3-keyboard: picker-grid arrow navigation.
import XCTest

import OstMacCore

final class GridNavTests: XCTestCase {
    func testEmptyStaysZero() {
        XCTAssertEqual(GridNav.move(current: 0, dx: 1, dy: 0, columns: 4, count: 0), 0)
        XCTAssertEqual(GridNav.move(current: 5, dx: 0, dy: 1, columns: 4, count: 0), 0)
    }

    func testHorizontalStepsWithoutWrap() {
        XCTAssertEqual(GridNav.move(current: 0, dx: 1, dy: 0, columns: 4, count: 10), 1)
        XCTAssertEqual(GridNav.move(current: 0, dx: -1, dy: 0, columns: 4, count: 10), 0)
        XCTAssertEqual(GridNav.move(current: 3, dx: 1, dy: 0, columns: 4, count: 10), 3)
        XCTAssertEqual(GridNav.move(current: 4, dx: -1, dy: 0, columns: 4, count: 10), 4)
    }

    func testVerticalStepsByColumns() {
        XCTAssertEqual(GridNav.move(current: 1, dx: 0, dy: 1, columns: 4, count: 12), 5)
        XCTAssertEqual(GridNav.move(current: 5, dx: 0, dy: -1, columns: 4, count: 12), 1)
        XCTAssertEqual(GridNav.move(current: 2, dx: 0, dy: -1, columns: 4, count: 12), 2)
        XCTAssertEqual(GridNav.move(current: 9, dx: 0, dy: 1, columns: 4, count: 12), 9)
    }

    func testShortLastRowClampsToLastItem() {
        // 10 items, 4 cols: last row holds 8,9. Down from 7 (row 1,
        // col 3) has no col-3 cell below → lands on 9, never past end.
        XCTAssertEqual(GridNav.move(current: 7, dx: 0, dy: 1, columns: 4, count: 10), 9)
        XCTAssertEqual(GridNav.move(current: 6, dx: 0, dy: 1, columns: 4, count: 10), 9)
        XCTAssertEqual(GridNav.move(current: 9, dx: 0, dy: 1, columns: 4, count: 10), 9)
    }

    func testDegenerateColumnsTreatedAsOne() {
        XCTAssertEqual(GridNav.move(current: 0, dx: 0, dy: 1, columns: 0, count: 3), 1)
        XCTAssertEqual(GridNav.move(current: 2, dx: 0, dy: 1, columns: -2, count: 3), 2)
    }

    func testCurrentOutOfRangeClamps() {
        XCTAssertEqual(GridNav.move(current: 99, dx: 0, dy: 0, columns: 4, count: 10), 9)
        XCTAssertEqual(GridNav.move(current: -3, dx: 1, dy: 0, columns: 4, count: 10), 1)
    }
}
