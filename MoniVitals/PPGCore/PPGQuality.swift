//
//  PPGQuality.swift
//  MoniVitals — PPGCore
//
//  Internal 0…1 signal-quality score from weighted sub-metrics. The composite is
//  the ONLY number the state machine consumes; the sub-scores exist for debug.
//  Nothing here is ever shown to the user.
//

import Foundation

struct PPGQualityScore: Equatable {
    var composite: Double      // 0…1 (EWMA-smoothed)
    var periodicity: Double
    var acdc: Double
    var consistency: Double
    var saturation: Double     // 1 = clean, 0 = fully clipped
    var timing: Double         // 1 = regular frame cadence
    var intensity: Double      // 1 = plausible brightness
    var motion: Double         // 1 = still
    var fingerPresence: Double

    static let zero = PPGQualityScore(composite: 0, periodicity: 0, acdc: 0,
                                      consistency: 0, saturation: 0, timing: 0,
                                      intensity: 0, motion: 0, fingerPresence: 0)
}

final class PPGQualityEstimator {
    private let cfg: PPGConfig
    private var smoothed: Double = 0

    // Weights sum to 1.0. Periodicity + finger presence dominate; the rest trim.
    private let wPeriodicity = 0.28
    private let wAcdc        = 0.15
    private let wConsistency = 0.14
    private let wSaturation  = 0.10
    private let wTiming      = 0.05
    private let wIntensity   = 0.05
    private let wMotion      = 0.10
    private let wFinger      = 0.13

    init(config: PPGConfig) { self.cfg = config }

    /// - Parameters:
    ///   - filtered: band-passed pulse window (newest last).
    ///   - green: raw green window (for AC/DC).
    ///   - dts: recent inter-frame intervals (µs) for timing regularity.
    ///   - satFraction: latest clipped-pixel fraction.
    ///   - motionLevel: 0…1 from PPGMotionProvider.
    ///   - fingerProb: 0…1 from PPGFingerDetector.
    ///   - fs: sample rate (Hz).
    func score(filtered: [Double], green: [Double], dts: [Double],
               satFraction: Double, motionLevel: Double, fingerProb: Double,
               fs: Double) -> PPGQualityScore {
        let periodicity = Self.periodicityScore(filtered, fs: fs)
        let acdc = Self.acdcScore(green)
        let consistency = Self.consistencyScore(filtered, fs: fs)
        let saturation = clamp(1.0 - satFraction * 6.0, 0, 1)   // penalise clipping hard
        let timing = Self.timingScore(dts)
        let intensity = Self.intensityScore(green)
        let motion = clamp(1.0 - motionLevel, 0, 1)
        let finger = clamp(fingerProb, 0, 1)

        var raw = wPeriodicity * periodicity + wAcdc * acdc + wConsistency * consistency
            + wSaturation * saturation + wTiming * timing + wIntensity * intensity
            + wMotion * motion + wFinger * finger
        // No pulse, no reading: brightness alone is not enough. This multiplicative
        // gate makes weak/flat contact fall out quickly without punishing a strong
        // periodic signal.
        raw *= clamp(0.45 + 0.55 * min(periodicity, max(acdc, 0.05)), 0, 1)
        smoothed += cfg.qualityEwmaAlpha * (raw - smoothed)

        return PPGQualityScore(composite: clamp(smoothed, 0, 1),
                               periodicity: periodicity, acdc: acdc,
                               consistency: consistency, saturation: saturation,
                               timing: timing, intensity: intensity,
                               motion: motion, fingerPresence: finger)
    }

    func reset() { smoothed = 0 }

    // MARK: - sub-metrics

    /// Sharpness of the autocorrelation peak in the plausible HR lag range.
    static func periodicityScore(_ x: [Double], fs: Double) -> Double {
        let n = x.count
        guard n > Int(fs) else { return 0 }
        let minLag = max(1, Int(fs * 60.0 / 200.0))
        let maxLag = min(n - 1, Int(fs * 60.0 / 40.0))
        guard maxLag > minLag else { return 0 }
        var zero = 0.0
        for v in x { zero += v * v }
        guard zero > 0 else { return 0 }
        // Require a minimum overlap so the normalised value at the largest lags
        // (averaged over only a few product terms) can't spuriously win the peak.
        let minOverlap = max(8, n / 4)
        var best = 0.0
        for lag in minLag...maxLag {
            if n - lag < minOverlap { continue }
            var s = 0.0
            var i = lag
            while i < n { s += x[i] * x[i - lag]; i += 1 }
            let norm = s / Double(n - lag) / (zero / Double(n))
            if norm > best { best = norm }
        }
        return clamp(best, 0, 1)
    }

    /// AC/DC ratio on the green channel, mapped to 0…1.
    static func acdcScore(_ green: [Double]) -> Double {
        guard green.count > 4 else { return 0 }
        let m = mean(green)
        guard m > 0 else { return 0 }
        let ac = stddev(green) / m
        return clamp(mapRange(ac, 0.002, 0.025, 0, 1), 0, 1)
    }

    /// Beat-to-beat template correlation: correlate a ~1 s tail against the signal
    /// one beat period earlier. The period isn't known here, so take the best
    /// correlation over the plausible beat-period lags — the old fixed 1 s shift
    /// only scored well when the rate happened to sit near a multiple of 60 bpm.
    static func consistencyScore(_ x: [Double], fs: Double) -> Double {
        let n = x.count
        let win = Int(fs)                      // ~1 s of support at every lag
        let minLag = max(2, Int((fs * 60.0 / 200.0).rounded(.up)))   // 200 bpm
        let maxLag = min(n - win, Int(fs * 60.0 / 40.0))             // 40 bpm
        guard win > 4, maxLag > minLag else { return 0 }
        var best = 0.0
        for lag in minLag...maxLag {
            let a = Array(x.suffix(win + lag).prefix(win))
            let b = Array(x.suffix(win))
            let c = Self.correlation(a, b)
            if c > best { best = c }
        }
        return clamp(best, 0, 1)
    }

    /// Bright-but-not-blown green range is plausible fingertip transmission.
    static func intensityScore(_ green: [Double]) -> Double {
        guard !green.isEmpty else { return 0 }
        let m = mean(green)
        // best around ~60…200; poor when very dim or fully blown.
        if m < 25 || m > 242 { return 0.1 }
        return clamp(mapRange(m, 20, 60, 0.3, 1.0), 0.3, 1.0)
    }

    /// Regular frame cadence ⇒ trustworthy time-base.
    static func timingScore(_ dts: [Double]) -> Double {
        guard dts.count > 3 else { return 0.5 }
        let m = mean(dts)
        guard m > 0 else { return 0 }
        let jitter = stddev(dts) / m
        return clamp(1.0 - jitter * 3.0, 0, 1)
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let aa = Array(a.suffix(n)), bb = Array(b.suffix(n))
        let ma = mean(aa), mb = mean(bb)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<n {
            let x = aa[i] - ma, y = bb[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }
}
