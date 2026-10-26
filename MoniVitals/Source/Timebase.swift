//
//  Timebase.swift
//  MoniVitals
//
//  Timestamp handling. A uint32 microsecond counter wraps every ≈71.6 min; the
//  extender turns it into a monotonically increasing 64-bit-safe value, and the
//  sequence tracker counts any skipped packets.
//
//  Extended timestamps are kept as Double to match the packet `tUs` type (a
//  Double exactly represents integers up to 2^53).
//

import Foundation

private let WRAP = 4_294_967_296.0 // 2^32

/// Extends a wrapping uint32 µs counter to a monotonically increasing value.
final class TimebaseExtender {
    private var epoch = 0.0
    private var lastRaw: Double? = nil

    func extend(_ raw: Double) -> Double {
        if let last = lastRaw, raw < last, last - raw > WRAP / 2 {
            epoch += 1 // a genuine wrap (large backward jump), not jitter
        }
        lastRaw = raw
        return epoch * WRAP + raw
    }

    func reset() {
        epoch = 0
        lastRaw = nil
    }
}

/// Per-stream sequence tracking to count dropped packets (seq is uint16).
final class SeqTracker {
    private var last: Int? = nil
    private(set) var dropped = 0

    /// Update with a new packet seq; returns the number of packets dropped before it.
    @discardableResult
    func update(_ seq: Int) -> Int {
        guard let last else {
            self.last = seq
            return 0
        }
        let gap = (seq - last - 1 + 0x10000) % 0x10000
        self.last = seq
        dropped += gap
        return gap
    }

    func reset() {
        last = nil
        dropped = 0
    }
}

/// Holds the pulse-stream extender + tracker.
final class Timebase {
    let extender = TimebaseExtender()
    let tracker = SeqTracker()

    func reset() {
        extender.reset()
        tracker.reset()
    }
}
