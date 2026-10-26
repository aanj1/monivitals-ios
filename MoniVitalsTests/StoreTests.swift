//
//  StoreTests.swift
//  MoniVitalsTests
//
//  Persistence-layer coverage for the local Store. Focus: the deleted-session
//  late-write guard — a Recorder.flush()-issued addChunk/addMetrics that lands
//  AFTER deleteSession must be dropped and must not re-create the on-disk file
//  as an orphan (mirrors the Android Store.deletedSessions semantics).
//

import XCTest
@testable import MoniVitals

final class StoreTests: XCTestCase {
    private let store = Store.shared

    func testLastVitalsDefaultDisplayDropsValuesAboveSafeRange() {
        let snapshot = LastVitalsSnapshot(
            capturedAt: "2026-01-01T00:00:00.000Z",
            source: .device,
            hrBpm: 118,
            respRateBpm: 26,
            rmssdMs: 42,
            sdnnMs: 51,
            signalQuality: 90,
            motion: 8,
            spo2Pct: 101
        ).sanitizedForDefaultDisplay

        XCTAssertNil(snapshot.hrBpm)
        XCTAssertNil(snapshot.respRateBpm)
        XCTAssertNil(snapshot.spo2Pct)
        XCTAssertEqual(snapshot.rmssdMs, 42)
        XCTAssertEqual(snapshot.sdnnMs, 51)
    }

    func testLastVitalsDefaultDisplayKeepsValuesInsideSafeRange() {
        let snapshot = LastVitalsSnapshot(
            capturedAt: "2026-01-01T00:00:00.000Z",
            source: .camera,
            hrBpm: 72,
            respRateBpm: 16,
            rmssdMs: 38,
            sdnnMs: 45,
            signalQuality: 88,
            motion: 10,
            spo2Pct: 98
        ).sanitizedForDefaultDisplay

        XCTAssertEqual(snapshot.hrBpm, 72)
        XCTAssertEqual(snapshot.respRateBpm, 16)
        XCTAssertEqual(snapshot.spo2Pct, 98)
    }

    /// The on-disk chunks file the store would write for `sessionId`.
    private func chunksFileURL(_ sessionId: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MoniVitals", isDirectory: true)
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent("\(Store.sanitizedId(sessionId)).json")
    }

    private func ppgChunk(_ sessionId: String) -> StreamChunk {
        var c = StreamChunk(id: nil, sessionId: sessionId, stream: .ppg,
                            tStartUs: 0, sampleRateHz: 30, t: [0, 33333])
        c.green = [120, 121]
        c.red = [200, 199]
        c.ir = [0, 0]
        return c
    }

    /// A chunk write that arrives after the session is deleted must be dropped
    /// and must not resurrect chunks/<id>.json.
    func testChunkWriteAfterDeleteDoesNotCreateFile() {
        let id = "test-late-write-\(UUID().uuidString)"
        let file = chunksFileURL(id)
        defer { try? FileManager.default.removeItem(at: file) }

        store.createSession(Session(id: id, subjectCode: "S01", label: .rest,
                                    startedAt: "2026-01-01T00:00:00.000Z",
                                    endedAt: nil, notes: ""))
        store.deleteSession(id)

        // Simulate a Recorder.flush() landing after the delete.
        store.addChunk(ppgChunk(id))
        store.flushPending()

        // `readSessionStreams` is a `queue.sync` read → acts as a barrier that
        // drains the async addChunk/flushPending above.
        let streams = store.readSessionStreams(id)
        XCTAssertTrue(streams.ppg.green.isEmpty, "late chunk must be dropped, not buffered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "deleted session's chunks file must not be re-created")
    }

    /// A metrics write that arrives after delete is likewise dropped.
    func testMetricsWriteAfterDeleteIsDropped() {
        let id = "test-late-metrics-\(UUID().uuidString)"
        store.createSession(Session(id: id, subjectCode: "S01", label: .rest,
                                    startedAt: "2026-01-01T00:00:00.000Z",
                                    endedAt: nil, notes: ""))
        store.deleteSession(id)

        store.addMetrics(MetricsRecord(id: nil, sessionId: id, tUs: 1000,
                                       hrBpm: 72, respRateBpm: 15, rmssdMs: 34,
                                       sdnnMs: 40, signalQuality: 88, motion: 12))
        store.flushPending()

        // `listMetrics` is a `queue.sync` read → drains the async writes above.
        XCTAssertTrue(store.listMetrics(id).isEmpty, "late metrics row must be dropped")
    }

    /// Re-using a deleted id for a fresh session clears the tombstone, so new
    /// writes for that id persist again.
    func testReusedSessionIdClearsTombstone() {
        let id = "test-reuse-\(UUID().uuidString)"
        let file = chunksFileURL(id)
        defer { store.deleteSession(id); try? FileManager.default.removeItem(at: file) }

        store.createSession(Session(id: id, subjectCode: "S01", label: .rest,
                                    startedAt: "2026-01-01T00:00:00.000Z",
                                    endedAt: nil, notes: ""))
        store.deleteSession(id)
        // A fresh session legitimately reuses the id → tombstone must clear.
        store.createSession(Session(id: id, subjectCode: "S01", label: .rest,
                                    startedAt: "2026-01-02T00:00:00.000Z",
                                    endedAt: nil, notes: ""))
        store.addChunk(ppgChunk(id))
        store.flushPending()

        let streams = store.readSessionStreams(id)
        XCTAssertEqual(streams.ppg.green, [120, 121],
                       "writes after id reuse must persist (tombstone cleared)")
    }
}
