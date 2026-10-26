//
//  PPGRingBuffer.swift
//  MoniVitals — PPGCore
//
//  Fixed-capacity time+value ring buffer for the measured/display numeric
//  histories the DSP walks each frame. Thread-safe (an NSLock) because the Canvas
//  may read while a frame writes.
//

import Foundation

final class PPGRingBuffer {
    private let cap: Int
    private var t: [Double]
    // Values kept as Double so band-passed samples aren't truncated to 32-bit before
    // the autocorrelation periodicity / consistency quality scoring reads them back.
    private var v: [Double]
    private var count = 0
    private var head = 0                 // next write index
    private let lock = NSLock()

    init(capacity: Int) {
        cap = max(2, capacity)
        t = [Double](repeating: 0, count: cap)
        v = [Double](repeating: 0, count: cap)
    }

    func push(_ tUs: Double, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        t[head] = tUs
        v[head] = value
        head = (head + 1) % cap
        if count < cap { count += 1 }
    }

    var length: Int { lock.lock(); defer { lock.unlock() }; return count }

    var latestT: Double? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return nil }
        return t[(head - 1 + cap) % cap]
    }

    var latestValue: Double? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return nil }
        return v[(head - 1 + cap) % cap]
    }

    /// All samples with timestamp >= `from`, oldest → newest.
    func window(from: Double) -> (t: [Double], v: [Double]) {
        lock.lock(); defer { lock.unlock() }
        var ts = [Double](); var vs = [Double]()
        ts.reserveCapacity(count); vs.reserveCapacity(count)
        let start = (head - count + cap) % cap
        for i in 0..<count {
            let idx = (start + i) % cap
            if t[idx] >= from {
                ts.append(t[idx]); vs.append(v[idx])
            }
        }
        return (ts, vs)
    }

    /// The most recent `n` values, oldest → newest.
    func tail(_ n: Int) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        let k = min(n, count)
        var out = [Double](); out.reserveCapacity(k)
        let start = (head - k + cap) % cap
        for i in 0..<k { out.append(v[(start + i) % cap]) }
        return out
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        count = 0; head = 0
    }
}
