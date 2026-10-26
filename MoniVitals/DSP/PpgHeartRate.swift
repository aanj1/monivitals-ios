//
//  PpgHeartRate.swift
//  MoniVitals
//
//  Heart rate from the camera pulse signal. Pure and testable on plain arrays:
//  detrend + band-pass into the heart-rate band, find beats by peak-picking with
//  a refractory gap, and fall back to autocorrelation when beats are noisy. The
//  reported value is a rolling median over the last few seconds so it stays calm.
//

import Foundation

/// Analyses a window of pulse samples and reports beats-per-minute.
///
/// Fully deterministic: feed it `(values, fs)` and it returns a bpm (or nil when
/// the signal is too weak/short to trust).
enum PpgHeartRate {

    /// Heart rate (bpm) from a window of pulse samples, or nil when unreliable.
    /// - Parameters:
    ///   - values: raw pulse samples (any units; DC is removed internally).
    ///   - fs: sample rate in Hz.
    static func estimate(_ values: [Double], fs: Double) -> Double? {
        guard fs > 0, values.count >= Int(fs * 2) else { return nil }

        let filtered = bandpassed(values, fs: fs)

        // Primary: count beats via peak-picking, convert mean beat spacing to bpm.
        if let bpm = peakRate(filtered, fs: fs), plausible(bpm) {
            return bpm
        }
        // Fallback: dominant period from autocorrelation.
        if let bpm = autocorrRate(filtered, fs: fs), plausible(bpm) {
            return bpm
        }
        return nil
    }

    // MARK: - Filtering

    /// Remove DC/slow drift then band-pass into the heart-rate band.
    static func bandpassed(_ values: [Double], fs: Double) -> [Double] {
        let m = mean(values)
        let centred = values.map { $0 - m }
        let bp = Biquad.bandpass(lowHz: DSPConstants.pulseBpLowHz,
                                 highHz: DSPConstants.pulseBpHighHz, fs: fs)
        // One causal forward pass — deliberately no second pass, so the peaks keep
        // their timing (a zero-phase double pass would need the whole window twice).
        var out = [Double]()
        out.reserveCapacity(centred.count)
        for v in centred { out.append(bp.process(v)) }
        return out
    }

    // MARK: - Peak-based rate

    /// Find beat peaks with an amplitude threshold + refractory gap; return bpm
    /// from the median beat-to-beat spacing.
    static func peakRate(_ x: [Double], fs: Double) -> Double? {
        guard x.count > 3 else { return nil }
        // Adaptive threshold: a fraction of the signal's positive std-dev.
        let sd = stddev(x)
        guard sd > 0 else { return nil }
        let thresh = 0.3 * sd
        // Refractory from the fastest plausible rate, so the picker can follow
        // rates right up to hrMaxBpm instead of clipping below it.
        let refractory = Int((60.0 / DSPConstants.hrMaxBpm) * fs)

        var peaks: [Int] = []
        var lastPeak = -refractory - 1
        for i in 1..<(x.count - 1) {
            let v = x[i]
            if v > thresh, v >= x[i - 1], v > x[i + 1], i - lastPeak > refractory {
                peaks.append(i)
                lastPeak = i
            }
        }
        guard peaks.count >= 3 else { return nil }

        var intervals: [Double] = []
        for k in 1..<peaks.count {
            intervals.append(Double(peaks[k] - peaks[k - 1]) / fs)
        }
        intervals = stableIntervals(intervals)
        guard intervals.count >= 2 else { return nil }
        let med = median(intervals)
        guard med > 0 else { return nil }
        return 60.0 / med
    }

    /// Keep beat spacings that agree with the dominant cadence. False local peaks
    /// create half-intervals; missed peaks create double-intervals. Both should be
    /// ignored before converting to BPM.
    static func stableIntervals(_ intervals: [Double]) -> [Double] {
        let plausible = intervals.filter {
            $0.isFinite &&
            $0 >= 60.0 / DSPConstants.hrMaxBpm &&
            $0 <= 60.0 / DSPConstants.hrMinBpm
        }
        guard plausible.count >= 4 else { return plausible }
        let med = median(plausible)
        guard med > 0 else { return plausible }
        return plausible.filter {
            let ratio = $0 / med
            return ratio >= 0.72 && ratio <= 1.38
        }
    }

    // MARK: - Autocorrelation fallback

    /// Dominant heart-rate period via autocorrelation over the plausible lag range.
    static func autocorrRate(_ x: [Double], fs: Double) -> Double? {
        let n = x.count
        guard n > 4 else { return nil }
        // Ceil the lower bound / floor the upper so truncation can't widen the
        // band past the plausible-rate limits.
        let minLag = Int((fs * 60.0 / DSPConstants.hrMaxBpm).rounded(.up))
        let maxLag = min(n - 1, Int((fs * 60.0 / DSPConstants.hrMinBpm).rounded(.down)))
        guard maxLag > minLag, minLag >= 1 else { return nil }

        // Energy at lag 0 for normalisation.
        var zero = 0.0
        for v in x { zero += v * v }
        guard zero > 0 else { return nil }

        // Require a minimum overlap so the normalised value at the largest lags
        // (averaged over only 1–2 product terms) can't spuriously win the peak.
        let minOverlap = max(8, n / 4)
        var bestLag = -1
        var bestVal = -Double.infinity
        for lag in minLag...maxLag {
            if n - lag < minOverlap { continue }
            var s = 0.0
            var i = lag
            while i < n {
                s += x[i] * x[i - lag]
                i += 1
            }
            // Normalise by overlap length: the raw sum has fewer terms as lag grows,
            // so without this it biases toward the smallest lag (fastest bpm).
            let norm = s / Double(n - lag)
            if norm > bestVal {
                bestVal = norm
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }
        return 60.0 * fs / Double(bestLag)
    }

    private static func plausible(_ bpm: Double) -> Bool {
        bpm.isFinite && bpm >= DSPConstants.hrMinBpm && bpm <= DSPConstants.hrMaxBpm
    }
}

/// Rolling heart-rate reporter driven off the camera window. Keeps a short median
/// so the number on screen doesn't jump around beat to beat.
final class PulseHeartRateReporter {
    private let buffer = RollingMedian(capacity: DSPConstants.hrMedianN)

    /// Feed a fresh per-window estimate (bpm). Returns the smoothed bpm.
    @discardableResult
    func push(_ bpm: Double?) -> Double? {
        if let bpm, bpm.isFinite { buffer.push(bpm) }
        return value()
    }

    func value() -> Double? {
        buffer.count < 2 ? nil : buffer.value()
    }

    func reset() { buffer.clear() }
}
