//
//  RespiratoryRate.swift
//  MoniVitals
//
//  Breathing rate from the camera pulse. Breathing gently swells and shrinks the
//  pulse's size and baseline; we pull out that slow rhythm (0.1–0.5 Hz) and count
//  how often it repeats. Pure and testable on plain arrays.
//

import Foundation

enum RespiratoryRate {

    /// Breaths per minute from a window of pulse samples, or nil when unreliable.
    /// Needs a longer window than heart rate (breathing is slow), so give it
    /// ~20 seconds for a stable read.
    /// - Parameters:
    ///   - values: raw pulse samples (DC removed internally).
    ///   - fs: sample rate in Hz.
    static func estimate(_ values: [Double], fs: Double) -> Double? {
        guard fs > 0 else { return nil }
        // Need enough data to see a couple of slow cycles.
        guard values.count >= Int(fs * 12) else { return nil }

        let resp = respiratoryBand(values, fs: fs)
        guard let bpm = dominantRate(resp, fs: fs), plausible(bpm) else { return nil }
        return bpm
    }

    /// Detrend then band-pass into the breathing band.
    static func respiratoryBand(_ values: [Double], fs: Double) -> [Double] {
        let m = mean(values)
        let centred = values.map { $0 - m }
        let bp = Biquad.bandpass(lowHz: DSPConstants.respBpLowHz,
                                 highHz: DSPConstants.respBpHighHz, fs: fs)
        var out = [Double]()
        out.reserveCapacity(centred.count)
        for v in centred { out.append(bp.process(v)) }
        return out
    }

    /// Dominant breathing period via autocorrelation over the plausible lag range.
    static func dominantRate(_ x: [Double], fs: Double) -> Double? {
        let n = x.count
        // Ceil the lower bound / floor the upper so truncation can't widen the
        // band past the plausible-rate limits.
        let minLag = Int((fs * 60.0 / DSPConstants.respMaxBpm).rounded(.up))
        let maxLag = min(n - 1, Int((fs * 60.0 / DSPConstants.respMinBpm).rounded(.down)))
        guard maxLag > minLag, minLag >= 1 else { return nil }

        var zero = 0.0
        for v in x { zero += v * v }
        guard zero > 0 else { return nil }

        // Require a minimum overlap so the normalized value at the largest lags
        // (averaged over only 1–2 product terms) can't spuriously win the peak.
        // The top of the range actually searched is therefore n - minOverlap,
        // which can sit below maxLag on short windows.
        let minOverlap = max(8, n / 4)
        let maxSearchedLag = min(maxLag, n - minOverlap)
        guard maxSearchedLag > minLag else { return nil }
        var bestLag = -1
        var bestVal = -Double.infinity
        for lag in minLag...maxSearchedLag {
            var s = 0.0
            var i = lag
            while i < n {
                s += x[i] * x[i - lag]
                i += 1
            }
            // Normalize by overlap length: longer lags have fewer terms, so the
            // raw sum would bias the winner toward small lags (fast rates).
            let norm = s / Double(n - lag)
            if norm > bestVal {
                bestVal = norm
                bestLag = lag
            }
        }
        // A winner sitting on the search boundary usually means the true rhythm is
        // outside (or barely inside) the band — an unreliable read, so compare
        // against the largest lag actually searched and report nothing rather
        // than a value pinned to the edge.
        guard bestLag > minLag, bestLag < maxSearchedLag else { return nil }
        // The breathing modulation must have a clear dominant rhythm. This avoids
        // surfacing random values from a mostly flat or erratic pulse envelope.
        guard bestVal > zero / Double(n) * 0.08 else { return nil }
        return 60.0 * fs / Double(bestLag)
    }

    private static func plausible(_ bpm: Double) -> Bool {
        bpm.isFinite && bpm >= DSPConstants.respMinBpm && bpm <= DSPConstants.respMaxBpm
    }
}
