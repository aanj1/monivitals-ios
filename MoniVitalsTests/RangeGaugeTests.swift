//
//  RangeGaugeTests.swift
//  MoniVitalsTests
//
//  Covers the pure `gaugePlacement` helper behind RangeGauge: the marker-fraction
//  math (clamped 0…1 along the span) and the zone-selection logic (which zone a
//  value lands in, matched by ordered `upTo` bounds). No SwiftUI is exercised —
//  the helper is a plain function, so this runs deterministically in the Simulator.
//

import SwiftUI
import XCTest
@testable import MoniVitals

final class RangeGaugeTests: XCTestCase {

    // Heart-rate-style zones: Low / Typical / Elevated / High over 40…140.
    private let hrSpan: ClosedRange<Double> = 40...140
    private let hrZones: [GaugeZone] = [
        GaugeZone(upTo: 50, color: MV.warn, label: "Low"),
        GaugeZone(upTo: 90, color: MV.good, label: "Typical"),
        GaugeZone(upTo: 110, color: MV.warn, label: "Elevated"),
        GaugeZone(upTo: 140, color: MV.bad, label: "High"),
    ]

    // MARK: - Marker fraction math

    func testFractionAtSpanMidpoint() {
        // 90 bpm on 40…140 → (90-40)/100 = 0.5
        let p = gaugePlacement(value: 90, span: hrSpan, zones: hrZones)
        XCTAssertEqual(p.fraction, 0.5, accuracy: 1e-9)
    }

    func testFractionAtSpanEnds() {
        XCTAssertEqual(gaugePlacement(value: 40, span: hrSpan, zones: hrZones).fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(gaugePlacement(value: 140, span: hrSpan, zones: hrZones).fraction, 1, accuracy: 1e-9)
    }

    func testFractionClampsBelowAndAbove() {
        // Below the span floor and above the ceiling both clamp to [0,1].
        XCTAssertEqual(gaugePlacement(value: 10, span: hrSpan, zones: hrZones).fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(gaugePlacement(value: 220, span: hrSpan, zones: hrZones).fraction, 1, accuracy: 1e-9)
    }

    // MARK: - Zone selection

    func testZoneSelectionAcrossBounds() {
        // 45 → Low (index 0); 72 → Typical (1); 100 → Elevated (2); 130 → High (3).
        XCTAssertEqual(gaugePlacement(value: 45, span: hrSpan, zones: hrZones).zoneIndex, 0)
        XCTAssertEqual(gaugePlacement(value: 72, span: hrSpan, zones: hrZones).zoneIndex, 1)
        XCTAssertEqual(gaugePlacement(value: 100, span: hrSpan, zones: hrZones).zoneIndex, 2)
        XCTAssertEqual(gaugePlacement(value: 130, span: hrSpan, zones: hrZones).zoneIndex, 3)
    }

    func testZoneBoundaryIsUpperExclusive() {
        // Exactly on an upper bound belongs to the NEXT zone (upTo is exclusive):
        // 50 is the top of "Low" → falls into "Typical" (index 1).
        XCTAssertEqual(gaugePlacement(value: 50, span: hrSpan, zones: hrZones).zoneIndex, 1)
        // 90 is the top of "Typical" → falls into "Elevated" (index 2).
        XCTAssertEqual(gaugePlacement(value: 90, span: hrSpan, zones: hrZones).zoneIndex, 2)
    }

    func testValueAboveAllBoundsFallsIntoLastZone() {
        // 500 exceeds every upTo → clamps into the final zone.
        XCTAssertEqual(gaugePlacement(value: 500, span: hrSpan, zones: hrZones).zoneIndex, 3)
    }

    // MARK: - Reversed-feel HRV zones (higher = good)

    func testHrvReversedZoneSelection() {
        let hrvZones: [GaugeZone] = [
            GaugeZone(upTo: 20, color: MV.bad, label: "Lower"),
            GaugeZone(upTo: 50, color: MV.warn, label: "Moderate"),
            GaugeZone(upTo: 120, color: MV.good, label: "Higher"),
        ]
        let span: ClosedRange<Double> = 0...120
        // 10 → Lower (0), 35 → Moderate (1), 80 → Higher (2).
        XCTAssertEqual(gaugePlacement(value: 10, span: span, zones: hrvZones).zoneIndex, 0)
        XCTAssertEqual(gaugePlacement(value: 35, span: span, zones: hrvZones).zoneIndex, 1)
        XCTAssertEqual(gaugePlacement(value: 80, span: span, zones: hrvZones).zoneIndex, 2)
        // Marker fraction: 60 on 0…120 → 0.5.
        XCTAssertEqual(gaugePlacement(value: 60, span: span, zones: hrvZones).fraction, 0.5, accuracy: 1e-9)
    }
}
