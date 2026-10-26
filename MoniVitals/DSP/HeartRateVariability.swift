//
//  HeartRateVariability.swift
//  MoniVitals
//
//  Heart-rate variability from beat-to-beat (RR) intervals. RMSSD captures the
//  quick beat-to-beat changes; SDNN captures the overall spread. Both are pure
//  functions over an array of intervals, so they're easy to test.
//

import Foundation

/// A pair of HRV summaries (milliseconds).
struct HRVResult: Equatable {
    var rmssdMs: Double
    var sdnnMs: Double
}

enum HeartRateVariability {

    /// Physiological ceiling for short-window camera HRV (ms). Healthy adult
    /// RMSSD/SDNN on a ~1-minute fingertip read sits well under 200 ms; anything
    /// beyond means the beats were mis-detected, so no value is reported.
    static let maxPlausibleMs = 200.0

    /// RMSSD + SDNN from RR intervals given in milliseconds.
    /// Returns nil until there are at least 8 clean intervals and 6 clean
    /// successive pairs, or when the result is outside the plausible range.
    static func compute(rrMs: [Double]) -> HRVResult? {
        let rr = cleanedIntervals(rrMs)
        guard rr.count >= 8 else { return nil }
        let diffs = successiveDiffs(rrMs)
        guard diffs.count >= 6 else { return nil }
        var sumSq = 0.0
        for d in diffs { sumSq += d * d }
        let rms = (sumSq / Double(diffs.count)).squareRoot()
        let sd = sdnn(rr)
        guard rms <= maxPlausibleMs, sd <= maxPlausibleMs else { return nil }
        return HRVResult(rmssdMs: rms, sdnnMs: sd)
    }

    /// Successive differences from originally-adjacent plausible pairs only.
    /// A missed beat doubles an interval and a false beat halves one; either
    /// inflates RMSSD enormously, so pairs differing by more than 20% are dropped
    /// (the standard ectopic/artifact criterion). Filtering pairs — rather than
    /// filtering intervals and then differencing the survivors — also avoids
    /// manufacturing differences between beats that were never adjacent.
    static func successiveDiffs(_ rrMs: [Double]) -> [Double] {
        guard rrMs.count >= 2 else { return [] }
        var out: [Double] = []
        for i in 1..<rrMs.count {
            let a = rrMs[i - 1], b = rrMs[i]
            guard a.isFinite, b.isFinite,
                  a >= 285, a <= 1500, b >= 285, b <= 1500 else { continue }
            let d = b - a
            if abs(d) <= 0.2 * ((a + b) / 2) { out.append(d) }
        }
        return out
    }

    /// Plausible RR intervals with ectopic / missed-beat outliers removed.
    /// A single false beat can dominate RMSSD, so keep only intervals close to the
    /// rolling median unless the window is still too small to judge.
    static func cleanedIntervals(_ rrMs: [Double]) -> [Double] {
        let plausible = rrMs.filter { $0.isFinite && $0 >= 285 && $0 <= 1500 }
        guard plausible.count >= 5 else { return plausible }
        let med = median(plausible)
        guard med > 0 else { return plausible }
        return plausible.filter { interval in
            let ratio = interval / med
            return ratio >= 0.8 && ratio <= 1.25
        }
    }

    /// Root mean square of successive differences (ms).
    static func rmssd(_ rrMs: [Double]) -> Double {
        guard rrMs.count >= 2 else { return 0 }
        var sumSq = 0.0
        for i in 1..<rrMs.count {
            let d = rrMs[i] - rrMs[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(rrMs.count - 1)).squareRoot()
    }

    /// Standard deviation of the RR intervals (ms).
    static func sdnn(_ rrMs: [Double]) -> Double {
        stddev(rrMs)
    }

    /// Convert a series of beat timestamps (µs) to RR intervals (ms). Implausible
    /// gaps become NaN placeholders rather than being dropped, so the array keeps
    /// one slot per original interval and `successiveDiffs` (whose isFinite guard
    /// skips NaN pairs) never pairs intervals that weren't truly adjacent.
    /// `cleanedIntervals` filters the NaNs out before any statistics.
    static func rrIntervalsMs(fromBeatsUs beats: [Double]) -> [Double] {
        guard beats.count >= 2 else { return [] }
        var out: [Double] = []
        for i in 1..<beats.count {
            let ms = (beats[i] - beats[i - 1]) / 1000.0
            // Plausible RR window: 40–210 bpm ≈ 285–1500 ms.
            out.append(ms >= 285 && ms <= 1500 ? ms : Double.nan)
        }
        return out
    }
}

/// Rolling HRV reporter fed by beat timestamps (µs) as the camera detects them.
final class HeartRateVariabilityReporter {
    private var beats: [Double] = []
    /// Keep roughly the last ~60 s of beats for a stable HRV read.
    private let windowUs = 60.0 * DSPConstants.usPerS

    func addBeat(_ tUs: Double) {
        beats.append(tUs)
        let cutoff = tUs - windowUs
        while let first = beats.first, first < cutoff { beats.removeFirst() }
    }

    func result() -> HRVResult? {
        let rr = HeartRateVariability.rrIntervalsMs(fromBeatsUs: beats)
        return HeartRateVariability.compute(rrMs: rr)
    }

    func reset() { beats.removeAll(keepingCapacity: true) }
}
