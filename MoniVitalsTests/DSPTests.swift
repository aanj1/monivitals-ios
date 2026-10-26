//
//  DSPTests.swift
//  MoniVitalsTests
//
//  RollingStats + Timebase coverage. Pure functions over plain arrays — no
//  camera or hardware needed. The pulse-DSP coverage lives in PpgDSPTests.
//

import XCTest
@testable import MoniVitals

final class RollingStatsTests: XCTestCase {
    func testMedianOddEvenNoMutation() {
        let a = [3.0, 1, 2]
        XCTAssertEqual(median(a), 2)
        XCTAssertEqual(a, [3, 1, 2]) // unchanged
        XCTAssertEqual(median([4, 1, 3, 2]), 2.5)
    }

    func testMeanVarianceStddev() {
        XCTAssertEqual(mean([2, 4, 6]), 4)
        XCTAssertEqual(variance([2, 4, 6]), 8.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(stddev([2, 4, 6]), (8.0 / 3.0).squareRoot(), accuracy: 1e-6)
    }

    func testClampAndMapRange() {
        XCTAssertEqual(clamp(5, 0, 3), 3)
        XCTAssertEqual(clamp(-1, 0, 3), 0)
        XCTAssertEqual(mapRange(5, 0, 10, 0, 100), 50)
        XCTAssertEqual(mapRange(0, 0, 0, 7, 9), 7) // degenerate input range
    }

    func testRollingMedianFixedCapacity() {
        let rm = RollingMedian(capacity: 3)
        rm.push(10); rm.push(20); rm.push(30); rm.push(40) // evicts 10
        XCTAssertEqual(rm.count, 3)
        XCTAssertEqual(rm.value(), 30) // median of [20,30,40]
    }
}

final class TimebaseTests: XCTestCase {
    func testExtenderPassthrough() {
        let ext = TimebaseExtender()
        XCTAssertEqual(ext.extend(100), 100)
        XCTAssertEqual(ext.extend(200), 200)
    }

    func testExtenderAcrossWrap() {
        let ext = TimebaseExtender()
        let nearMax = Double(0xfffffff0)
        XCTAssertEqual(ext.extend(nearMax), nearMax)
        XCTAssertEqual(ext.extend(Double(0x10)), 4_294_967_296 + 16)
    }

    func testSeqTrackerCountsDrops() {
        let t = SeqTracker()
        XCTAssertEqual(t.update(10), 0) // first
        XCTAssertEqual(t.update(11), 0) // contiguous
        XCTAssertEqual(t.update(14), 2) // dropped 12,13
        XCTAssertEqual(t.dropped, 2)
        _ = t.update(65535)
        XCTAssertEqual(t.update(1), 1) // wrapped 65535 -> 0(dropped) -> 1
    }
}
