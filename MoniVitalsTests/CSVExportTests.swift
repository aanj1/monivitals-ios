//
//  CSVExportTests.swift
//  MoniVitalsTests
//
//  CSV escaping + fixed-header / blank-cell correctness for the pulse-only
//  export bundle. The iOS export produces a folder bundle (not a ZIP), so
//  zip-specific tests are not ported.
//

import XCTest
@testable import MoniVitals

final class CSVExportTests: XCTestCase {
    func testCsvEscape() {
        XCTAssertEqual(CSVExport.csvEscape("plain"), "plain")
        XCTAssertEqual(CSVExport.csvEscape(42 as Double), "42")
        XCTAssertEqual(CSVExport.csvEscape(nil as String?), "")
        XCTAssertEqual(CSVExport.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExport.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExport.csvEscape("line1\nline2"), "\"line1\nline2\"")
    }

    func testJsNumberFormatting() {
        XCTAssertEqual(CSVExport.jsNumber(215), "215")
        XCTAssertEqual(CSVExport.jsNumber(215000.0 / 1000.0), "215")
        XCTAssertEqual(CSVExport.jsNumber(72), "72")
        XCTAssertEqual(CSVExport.jsNumber(3906), "3906")
        XCTAssertEqual(CSVExport.jsNumber(0), "0")
    }

    func testBuildBundleFilesHeadersAndCells() {
        var streams = SessionStreams()
        streams.ppg.t = [0, 33333]
        streams.ppg.green = [120, 121]
        streams.ppg.red = [200, 199]
        streams.ppg.ir = [0, 0]

        let metrics = [
            MetricsRecord(id: 1, sessionId: "abc12345", tUs: 1000,
                          hrBpm: 72, respRateBpm: 15, rmssdMs: 34, sdnnMs: 40,
                          signalQuality: 88, motion: 12, spo2Pct: 98),
            MetricsRecord(id: 2, sessionId: "abc12345", tUs: 2000,
                          hrBpm: nil, respRateBpm: nil, rmssdMs: nil, sdnnMs: nil,
                          signalQuality: 10, motion: 200),
        ]

        let annotations = [
            Annotation(id: 1, sessionId: "abc12345", tUs: 2000, type: .marker, text: "note"),
        ]

        let bundle = BundleData(
            session: Session(
                id: "abc12345", subjectCode: "S01", label: .rest,
                startedAt: "2026-01-01T00:00:00.000Z", endedAt: nil, notes: ""),
            subject: Subject(code: "S01", ageBand: "20-29", sex: nil, notes: "",
                             createdAt: "2026-01-01T00:00:00.000Z"),
            streams: streams,
            metrics: metrics,
            annotations: annotations
        )

        let files = Dictionary(uniqueKeysWithValues:
            CSVExport.buildBundleFiles(bundle).map { ($0.name, $0.content) })

        // Pulse CSV: fixed header + one row per sample.
        let pulse = files["pulse.csv"]!
        XCTAssertTrue(pulse.hasPrefix("t_us,green,red\n"))
        XCTAssertTrue(pulse.contains("0,120,200"))
        XCTAssertTrue(pulse.contains("33333,121,199"))

        // Metrics CSV: fixed header; nil metrics become blank cells (not zero).
        let metricsCsv = files["metrics.csv"]!
        let metricsLines = metricsCsv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(metricsLines[0], "t_us,hr_bpm,resp_rate_bpm,rmssd_ms,sdnn_ms,signal_quality,movement,spo2_pct")
        XCTAssertEqual(metricsLines[1], "1000,72,15,34,40,88,12,98")
        XCTAssertEqual(metricsLines[2], "2000,,,,,10,200,")

        // Markers CSV.
        let markers = files["markers.csv"]!
        XCTAssertTrue(markers.hasPrefix("t_us,type,text\n"))
        XCTAssertTrue(markers.contains("2000,marker,note"))

        // Meta JSON: trimmed schema (v2), no calibration/gating/device.
        let meta = try! JSONSerialization.jsonObject(
            with: files["session_meta.json"]!.data(using: .utf8)!) as! [String: Any]
        let session = meta["session"] as! [String: Any]
        XCTAssertEqual(session["subjectCode"] as? String, "S01")
        XCTAssertNil(session["deviceId"])
        XCTAssertNil(meta["calibration"])
        XCTAssertEqual(meta["schemaVersion"] as? Int, 2)
    }
}
