//
//  PPGFilters.swift
//  MoniVitals — PPGCore
//
//  Streaming filter primitives: a band-pass biquad (own type, `PPGBiquad`, so it
//  doesn't clash with the existing `Biquad`), a baseline/DC tracker, and a light
//  beat detector that yields inter-beat intervals for periodicity + rate.
//  Reuses the module-global math helpers (mean/stddev/clamp).
//

import Foundation

/// Direct-form-II transposed biquad. Processes one sample at a time.
final class PPGBiquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    /// RBJ constant-skirt band-pass centred on √(low·high) with Q = f0/(high-low).
    init(lowHz: Double, highHz: Double, fs: Double) {
        let f0 = max(0.01, (lowHz * highHz).squareRoot())
        let bw = max(0.01, highHz - lowHz)
        let q = max(0.3, f0 / bw)
        let w0 = 2.0 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2.0 * q)
        let b0n = alpha
        let b1n = 0.0
        let b2n = -alpha
        let a0 = 1.0 + alpha
        let a1n = -2.0 * cos(w0)
        let a2n = 1.0 - alpha
        b0 = b0n / a0; b1 = b1n / a0; b2 = b2n / a0
        a1 = a1n / a0; a2 = a2n / a0
    }

    func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    func reset() { z1 = 0; z2 = 0 }

    /// Convenience: filter a whole array (fresh state).
    func filtered(_ xs: [Double]) -> [Double] {
        reset()
        return xs.map { process($0) }
    }
}

/// Slow-moving baseline estimate (the DC the pulse rides on).
final class PPGBaselineTracker {
    private var value: Double?
    private let alpha: Double
    init(alpha: Double = 0.02) { self.alpha = alpha }
    func update(_ x: Double) -> Double {
        let v = value.map { $0 + alpha * (x - $0) } ?? x
        value = v
        return v
    }
    var current: Double? { value }
    func reset() { value = nil }
}

/// Emits a beat time (µs) when a systolic peak clears an adaptive threshold and
/// the refractory gap has elapsed. Kept intentionally simple + robust.
final class PPGBeatDetector {
    private var lastPeakUs: Double = -.infinity
    private var prev = 0.0, prevPrev = 0.0
    private var prevTUs = 0.0, prevPrevTUs = 0.0   // timestamps of prev / prevPrev
    private var recent: [Double] = []          // recent filtered magnitudes for threshold
    private let refractoryUs: Double
    private(set) var lastIbiMs: Double?

    init(maxBpm: Double = DSPConstants.hrMaxBpm) {
        // Refractory from the FASTEST plausible rate: at 210 bpm beats arrive every
        // ~285 ms, so any peak sooner than that is a false one. (Deriving it from
        // the slowest rate halved every rate above ~80 bpm.)
        refractoryUs = 60.0 / max(1, maxBpm) * 1_000_000.0
    }

    /// Feed one filtered sample; returns the beat time if this sample was a peak.
    /// The peak instant is sub-sampled by parabolic interpolation so IBIs (and thus
    /// HRV) are NOT quantized to the frame grid — snapping a peak to the 33 ms 30-fps
    /// grid alone fabricates ~25 ms of RMSSD on a perfectly regular pulse.
    @discardableResult
    func process(_ x: Double, tUs: Double) -> Double? {
        recent.append(x)
        if recent.count > 90 { recent.removeFirst(recent.count - 90) }
        let sd = stddev(recent)
        let thresh = 0.4 * sd
        var beat: Double? = nil
        // prevPrev, prev, x  → prev is a local max above threshold
        if prev > thresh, prev >= prevPrev, prev > x {
            // Parabolic vertex offset δ (in samples, +right / -left) of (prevPrev, prev, x).
            let denom = prevPrev - 2.0 * prev + x
            var delta = abs(denom) > 1e-12 ? 0.5 * (prevPrev - x) / denom : 0.0
            delta = min(1.0, max(-1.0, delta))
            // Map δ onto real time via the LOCAL dt (prev→now) so fps drift / drops
            // don't distort the interpolated instant.
            let interpPeak = prevTUs + delta * (tUs - prevTUs)
            if interpPeak - lastPeakUs > refractoryUs {
                if lastPeakUs.isFinite { lastIbiMs = (interpPeak - lastPeakUs) / 1000.0 }
                lastPeakUs = interpPeak
                beat = interpPeak
            }
        }
        prevPrev = prev; prevPrevTUs = prevTUs
        prev = x; prevTUs = tUs
        return beat
    }

    func reset() {
        lastPeakUs = -.infinity; prev = 0; prevPrev = 0
        prevTUs = 0; prevPrevTUs = 0
        recent.removeAll(); lastIbiMs = nil
    }

    /// Resync local peak-shape state across a detected time gap WITHOUT wiping the
    /// last-peak anchor: clears prev/prevPrev so the gap frame can't read as a local
    /// max, but keeps `lastPeakUs` so the refractory window stays honest.
    func resyncAcrossGap() {
        prev = 0; prevPrev = 0; prevTUs = 0; prevPrevTUs = 0
    }
}
