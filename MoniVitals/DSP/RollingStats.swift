//
//  RollingStats.swift
//  MoniVitals
//
//  Small statistics helpers used by the metric reporters.
//  Ported from web/src/dsp/rollingStats.ts.
//

import Foundation

// MARK: - Free functions

/// Median of a numeric array (does not mutate the input). Returns NaN for empty input.
func median(_ values: [Double]) -> Double {
    if values.isEmpty { return .nan }
    let sorted = values.sorted()
    let mid = sorted.count >> 1
    return sorted.count % 2 != 0 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/// Arithmetic mean. Returns NaN for empty input.
func mean(_ values: [Double]) -> Double {
    if values.isEmpty { return .nan }
    var s = 0.0
    for v in values { s += v }
    return s / Double(values.count)
}

/// Population variance. Returns 0 for empty input.
func variance(_ values: [Double]) -> Double {
    let n = values.count
    if n == 0 { return 0 }
    let m = mean(values)
    var s = 0.0
    for v in values {
        let d = v - m
        s += d * d
    }
    return s / Double(n)
}

/// Population standard deviation.
func stddev(_ values: [Double]) -> Double {
    variance(values).squareRoot()
}

/// Clamp `x` into `[lo, hi]`.
func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    x < lo ? lo : (x > hi ? hi : x)
}

/// Linear map from one range to another (unclamped).
func mapRange(_ x: Double, _ inLo: Double, _ inHi: Double, _ outLo: Double, _ outHi: Double) -> Double {
    if inHi == inLo { return outLo }
    return outLo + ((x - inLo) * (outHi - outLo)) / (inHi - inLo)
}

// MARK: - RollingMedian

/// Fixed-capacity ring of recent values that reports its rolling median.
final class RollingMedian {
    private var buf: [Double] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func push(_ v: Double) {
        buf.append(v)
        if buf.count > capacity { buf.removeFirst() }
    }

    var count: Int { buf.count }

    func value() -> Double { median(buf) }

    func clear() { buf.removeAll(keepingCapacity: true) }
}
