//
//  Store.swift
//  MoniVitals
//
//  Dependency-free, local-first persistence. Stores data as JSON files under
//  Application Support:
//
//      <AppSupport>/MoniVitals/
//        subjects.json          [Subject]
//        sessions.json          [Session]
//        annotations.json       [Annotation]
//        chunks/<sessionId>.json     [StreamChunk]   (pulse sample blocks)
//        metrics/<sessionId>.json    [MetricsRecord]
//
//  Per-session sample data lives in its own file so listing/deleting sessions never
//  loads every pulse trace. All access is serialized on a private queue.
//

import Foundation

/// Concatenated, contiguous pulse samples for a session (review / export).
struct SessionStreams {
    struct Ppg { var t: [Double]; var green: [UInt32]; var red: [UInt32]; var ir: [UInt32] }
    var ppg = Ppg(t: [], green: [], red: [], ir: [])
}

/// The local data store. A single shared instance is used by the app.
final class Store {
    static let shared = Store()

    private let queue = DispatchQueue(label: "com.monivitals.store")
    private let fm = FileManager.default
    private let root: URL
    private let chunksDir: URL
    private let metricsDir: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    // In-memory append buffers for the high-rate writers (metrics ~4×/s, chunks
    // ~every few seconds). Flushed to the per-session JSON files periodically and
    // on end/stop, so recording never rewrites a growing file on every tick.
    // Only ever touched on `queue`.
    private var pendingMetrics: [String: [MetricsRecord]] = [:]
    private var pendingChunks: [String: [StreamChunk]] = [:]
    // Sessions deleted while a Recorder io-task was still in flight. A chunk/metrics
    // append that lands AFTER deleteSession would otherwise re-create
    // chunks/<id>.json as an orphan, so buffered writes for these ids are dropped
    // and their files kept deleted. Cleared on createSession (a fresh session may
    // legitimately reuse a prior id). Only ever touched on `queue`.
    private var deletedSessions: Set<String> = []
    private var lastPendingFlush = Date()
    private static let pendingFlushInterval: TimeInterval = 10

    private init() {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("MoniVitals", isDirectory: true)
        chunksDir = root.appendingPathComponent("chunks", isDirectory: true)
        metricsDir = root.appendingPathComponent("metrics", isDirectory: true)
        encoder = JSONEncoder()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: metricsDir, withIntermediateDirectories: true)
    }

    // MARK: - file helpers

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// File-name-safe form of a session id. Ids can arrive from remote Firestore
    /// docs, so anything outside [A-Za-z0-9._-] (path separators etc.) is replaced
    /// before the id is used to build a file path.
    static func sanitizedId(_ id: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let safe = String(id.map { allowed.contains($0) ? $0 : "_" })
        return safe.isEmpty ? "_" : safe
    }

    private func metricsFile(_ sessionId: String) -> URL {
        metricsDir.appendingPathComponent("\(Self.sanitizedId(sessionId)).json")
    }

    private func chunksFile(_ sessionId: String) -> URL {
        chunksDir.appendingPathComponent("\(Self.sanitizedId(sessionId)).json")
    }

    private func load<T: Decodable>(_ url: URL, default def: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return def }
        return (try? decoder.decode(T.self, from: data)) ?? def
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func nextId(_ items: [Int?]) -> Int {
        (items.compactMap { $0 }.max() ?? 0) + 1
    }

    // MARK: - Subjects

    func upsertSubject(_ s: Subject) {
        queue.sync {
            var all: [Subject] = load(url("subjects.json"), default: [])
            all.removeAll { $0.code == s.code }
            all.append(s)
            save(all, to: url("subjects.json"))
        }
    }

    /// Subjects, newest first (by createdAt) — matches the web `listSubjects`.
    func listSubjects() -> [Subject] {
        queue.sync {
            let all: [Subject] = load(url("subjects.json"), default: [])
            return all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func getSubject(_ code: String) -> Subject? {
        queue.sync {
            let all: [Subject] = load(url("subjects.json"), default: [])
            return all.first { $0.code == code }
        }
    }

    func deleteSubject(_ code: String) {
        // Delete the subject's sessions, then the subject.
        let sessions = listSessions().filter { $0.subjectCode == code }
        for s in sessions { deleteSession(s.id) }
        queue.sync {
            var subs: [Subject] = load(url("subjects.json"), default: [])
            subs.removeAll { $0.code == code }
            save(subs, to: url("subjects.json"))
        }
    }

    // MARK: - Sessions

    func createSession(_ s: Session) {
        queue.sync {
            deletedSessions.remove(s.id) // a fresh session may legitimately reuse a prior id
            var all: [Session] = load(url("sessions.json"), default: [])
            all.removeAll { $0.id == s.id }
            all.append(s)
            save(all, to: url("sessions.json"))
        }
    }

    func endSession(_ id: String, endedAt: String) {
        queue.sync {
            // A finished recording must be fully on disk, buffered rows included.
            flushPendingLocked(session: id)
            var all: [Session] = load(url("sessions.json"), default: [])
            if let idx = all.firstIndex(where: { $0.id == id }) {
                all[idx].endedAt = endedAt
                save(all, to: url("sessions.json"))
            }
        }
    }

    func getSession(_ id: String) -> Session? {
        queue.sync {
            let all: [Session] = load(url("sessions.json"), default: [])
            return all.first { $0.id == id }
        }
    }

    /// Sessions, newest first (by startedAt).
    func listSessions() -> [Session] {
        queue.sync {
            let all: [Session] = load(url("sessions.json"), default: [])
            return all.sorted { $0.startedAt > $1.startedAt }
        }
    }

    func deleteSession(_ id: String) {
        queue.sync {
            pendingMetrics[id] = nil
            pendingChunks[id] = nil
            // Tombstone the id so a Recorder.flush()-issued addChunk/addMetrics that
            // lands after this delete is dropped instead of re-creating the file.
            deletedSessions.insert(id)
            var sessions: [Session] = load(url("sessions.json"), default: [])
            sessions.removeAll { $0.id == id }
            save(sessions, to: url("sessions.json"))
            var annos: [Annotation] = load(url("annotations.json"), default: [])
            annos.removeAll { $0.sessionId == id }
            save(annos, to: url("annotations.json"))
            try? fm.removeItem(at: chunksFile(id))
            try? fm.removeItem(at: metricsFile(id))
        }
    }

    // MARK: - Annotations

    @discardableResult
    func addAnnotation(_ a: Annotation) -> Int {
        queue.sync {
            var all: [Annotation] = load(url("annotations.json"), default: [])
            var item = a
            item.id = nextId(all.map { $0.id })
            all.append(item)
            save(all, to: url("annotations.json"))
            return item.id!
        }
    }

    func listAnnotations(_ sessionId: String) -> [Annotation] {
        queue.sync {
            let all: [Annotation] = load(url("annotations.json"), default: [])
            return all.filter { $0.sessionId == sessionId }.sorted { $0.tUs < $1.tUs }
        }
    }

    // MARK: - Metrics

    /// Append a readings row. Buffered in memory and flushed off the caller's
    /// thread (periodically + on end/stop), so the 4×/s recording tick never
    /// decodes-and-rewrites the whole session file on the main thread.
    func addMetrics(_ m: MetricsRecord) {
        queue.async {
            if self.deletedSessions.contains(m.sessionId) { return } // late write after delete — drop it
            self.pendingMetrics[m.sessionId, default: []].append(m)
            self.flushPendingIfDueLocked()
        }
    }

    func listMetrics(_ sessionId: String) -> [MetricsRecord] {
        queue.sync {
            let all: [MetricsRecord] = load(metricsFile(sessionId), default: [])
                + (pendingMetrics[sessionId] ?? [])
            return all.sorted { $0.tUs < $1.tUs }
        }
    }

    // MARK: - Stream chunks

    /// Append a pulse-sample block. Buffered like `addMetrics`.
    func addChunk(_ chunk: StreamChunk) {
        queue.async {
            if self.deletedSessions.contains(chunk.sessionId) { return } // late write after delete — drop it
            self.pendingChunks[chunk.sessionId, default: []].append(chunk)
            self.flushPendingIfDueLocked()
        }
    }

    private func chunks(_ sessionId: String) -> [StreamChunk] {
        let all: [StreamChunk] = load(chunksFile(sessionId), default: [])
            + (pendingChunks[sessionId] ?? [])
        return all.sorted { $0.tStartUs < $1.tStartUs }
    }

    // MARK: - Pending-buffer flushing (always on `queue`)

    /// Flush every buffered row/chunk to disk. Call when recording stops or the
    /// app is backgrounded so a crash can't cost more than a few seconds of data.
    func flushPending() {
        queue.async { self.flushAllPendingLocked() }
    }

    private func flushPendingIfDueLocked() {
        guard Date().timeIntervalSince(lastPendingFlush) >= Self.pendingFlushInterval else { return }
        flushAllPendingLocked()
    }

    private func flushAllPendingLocked() {
        for id in Set(pendingMetrics.keys).union(pendingChunks.keys) {
            flushPendingLocked(session: id)
        }
        lastPendingFlush = Date()
    }

    private func flushPendingLocked(session id: String) {
        // Guard against a late flush for a session deleted since the buffer filled:
        // drop its buffered rows/chunks rather than re-creating the on-disk files.
        if deletedSessions.contains(id) {
            pendingMetrics[id] = nil
            pendingChunks[id] = nil
            return
        }
        if let rows = pendingMetrics.removeValue(forKey: id), !rows.isEmpty {
            let file = metricsFile(id)
            var all: [MetricsRecord] = load(file, default: [])
            var next = nextId(all.map { $0.id })
            for var row in rows {
                row.id = next
                next += 1
                all.append(row)
            }
            save(all, to: file)
        }
        if let blocks = pendingChunks.removeValue(forKey: id), !blocks.isEmpty {
            let file = chunksFile(id)
            var all: [StreamChunk] = load(file, default: [])
            var next = nextId(all.map { $0.id })
            for var block in blocks {
                block.id = next
                next += 1
                all.append(block)
            }
            save(all, to: file)
        }
    }

    /// Concatenate stored chunks back into contiguous pulse arrays.
    func readSessionStreams(_ sessionId: String) -> SessionStreams {
        queue.sync {
            let all = chunks(sessionId)
            var out = SessionStreams()
            for c in all where c.stream == .ppg {
                out.ppg.t += c.t
                out.ppg.green += c.green ?? []
                out.ppg.red += c.red ?? []
                out.ppg.ir += c.ir ?? []
            }
            return out
        }
    }

    /// Wipe every stored table (Settings → data management).
    func deleteAllData() {
        queue.sync {
            // Tombstone every currently-known session id so a Recorder.flush() still
            // in flight can't re-create an orphan chunks/metrics file after the wipe.
            let existing: [Session] = load(url("sessions.json"), default: [])
            for s in existing { deletedSessions.insert(s.id) }
            for id in pendingMetrics.keys { deletedSessions.insert(id) }
            for id in pendingChunks.keys { deletedSessions.insert(id) }
            pendingMetrics.removeAll()
            pendingChunks.removeAll()
            for name in ["subjects.json", "sessions.json", "annotations.json"] {
                try? fm.removeItem(at: url(name))
            }
            try? fm.removeItem(at: chunksDir)
            try? fm.removeItem(at: metricsDir)
            try? fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: metricsDir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Recorder

/// Buffers live pulse samples and flushes them to the store in chunks. One
/// instance per active measurement. Robust to interruptions (flush on stop).
final class Recorder {
    let sessionId: String
    private(set) var counts: [StreamKind: Int] = [.ppg: 0]

    private final class BufferState {
        var tStartUs: Double? = nil
        var rate = 0
        var t: [Double] = []
        var green: [Double] = []
        var red: [Double] = []
        var ir: [Double] = []
    }

    private var ppg = BufferState()
    private let flushSamples = 300
    private let store: Store

    init(sessionId: String, store: Store = .shared) {
        self.sessionId = sessionId
        self.store = store
    }

    func ingestPpg(_ p: PpgPacket) {
        if ppg.tStartUs == nil { ppg.tStartUs = p.tUs }
        ppg.rate = p.sampleRateHz
        let dt = DSPConstants.usPerS / Double(p.sampleRateHz)
        for i in 0..<min(p.green.count, p.red.count) {
            // Record the REAL per-sample time when the camera bridge supplies it, so
            // pulse.csv's t_us reflects honest capture timing (fps drift / drops) and
            // not a synthetic grid; BLE has no timesUs → the formula still applies.
            ppg.t.append(i < p.timesUs.count ? p.timesUs[i] : p.tUs + (Double(i) * dt).rounded())
            ppg.green.append(p.green[i])
            ppg.red.append(p.red[i])
            ppg.ir.append(i < p.ir.count ? Double(p.ir[i]) : 0)
        }
        counts[.ppg, default: 0] += p.green.count
        if ppg.green.count >= flushSamples { flush() }
    }

    /// Persist buffered pulse samples as a StreamChunk.
    func flush() {
        guard !ppg.green.isEmpty, let tStart = ppg.tStartUs else { return }
        var chunk = StreamChunk(id: nil, sessionId: sessionId, stream: .ppg,
                                tStartUs: tStart, sampleRateHz: ppg.rate, t: ppg.t)
        chunk.green = ppg.green.map { UInt32(max(0, min($0.isFinite ? $0 : 0, 4_294_967_295)).rounded()) }
        chunk.red = ppg.red.map { UInt32(max(0, min($0.isFinite ? $0 : 0, 4_294_967_295)).rounded()) }
        chunk.ir = ppg.ir.map { UInt32(max(0, min($0.isFinite ? $0 : 0, 4_294_967_295)).rounded()) }
        ppg = BufferState()
        store.addChunk(chunk)
    }

    func flushAll() { flush() }
}
