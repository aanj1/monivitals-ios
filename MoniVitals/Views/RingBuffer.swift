//
//  RingBuffer.swift
//  MoniVitals
//
//  Fixed-capacity ring buffer of (deviceTimeUs, value) points for live waveform
//  rendering. Mutated at full sample rate by the packet handlers and read by the Canvas
//  on a TimelineView tick — never via @Published state, so the UI is not re-rendered per
//  sample.
//
//  Ported from web/src/live/ringBuffer.ts (WaveBuffer). Reads/writes are guarded by a
//  lock since the source delivers packets on a background queue while the Canvas reads
//  on the main thread.
//

import Foundation

final class WaveBuffer {
    let capacity: Int
    private var ts: [Double]
    private var vs: [Double]
    private var head = 0
    private var filled = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.ts = Array(repeating: 0, count: capacity)
        self.vs = Array(repeating: 0, count: capacity)
    }

    func push(_ t: Double, _ v: Double) {
        lock.lock()
        ts[head] = t
        vs[head] = v
        head = (head + 1) % capacity
        if filled < capacity { filled += 1 }
        lock.unlock()
    }

    var length: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    func latestT() -> Double? {
        lock.lock(); defer { lock.unlock() }
        if filled == 0 { return nil }
        return ts[(head - 1 + capacity) % capacity]
    }

    /// Points with timestamp ≥ tFrom, in chronological order.
    func window(from tFrom: Double) -> (t: [Double], v: [Double]) {
        lock.lock(); defer { lock.unlock() }
        var t: [Double] = []
        var v: [Double] = []
        t.reserveCapacity(filled)
        v.reserveCapacity(filled)
        for i in 0..<filled {
            let idx = (head - filled + i + capacity * 2) % capacity
            if ts[idx] >= tFrom {
                t.append(ts[idx])
                v.append(vs[idx])
            }
        }
        return (t, v)
    }

    func clear() {
        lock.lock()
        head = 0
        filled = 0
        lock.unlock()
    }
}

/// The non-reactive set of pulse waveform ring buffers.
final class WaveBuffers {
    let ppgGreen = WaveBuffer(capacity: 8192)
    let ppgRed = WaveBuffer(capacity: 8192)

    func clear() {
        ppgGreen.clear(); ppgRed.clear()
    }

    /// Latest timestamp seen in the pulse stream.
    func latestDeviceUs() -> Double {
        ppgGreen.latestT() ?? 0
    }
}
