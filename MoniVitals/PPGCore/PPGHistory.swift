//
//  PPGHistory.swift
//  MoniVitals — PPGCore
//
//  Rolling memory of what a CLEAN pulse recently looked like, so the reconstructor
//  can extend it convincingly during a brief dropout. Updated ONLY from good-quality
//  data — never from degraded/reconstructed samples.
//

import Foundation

final class PPGHistory {
    /// Median inter-beat interval (ms) over recent clean beats.
    private(set) var medianIbiMs: Double?
    /// Recent pulse amplitude (peak-to-peak of the filtered signal).
    private(set) var amplitude: Double = 1
    /// Recent baseline (raw green DC the pulse rides on). Informational only — the
    /// reconstructor synthesizes in the filtered, zero-centred display domain.
    private(set) var baseline: Double = 0
    /// A normalized single-beat template, resampled to `templateN` points, mean 0,
    /// unit-ish amplitude. Used as the reconstruction shape.
    private(set) var template: [Double] = []

    private var ibis: [Double] = []
    let templateN = 48

    /// Recent heart period in seconds (derived from the median IBI), if known.
    var periodS: Double? { medianIbiMs.map { $0 / 1000.0 } }

    /// Feed a good-quality beat: its IBI and the filtered samples spanning it.
    func addCleanBeat(ibiMs: Double?, beatSamples: [Double], baseline: Double) {
        if let ibi = ibiMs, ibi >= 285, ibi <= 1500 {
            ibis.append(ibi)
            if ibis.count > 12 { ibis.removeFirst(ibis.count - 12) }
            medianIbiMs = ibis.sorted()[ibis.count / 2]
        }
        guard beatSamples.count >= 4 else { return }
        let lo = beatSamples.min() ?? 0, hi = beatSamples.max() ?? 1
        let amp = max(1e-6, hi - lo)
        amplitude = 0.7 * amplitude + 0.3 * amp
        self.baseline = 0.7 * self.baseline + 0.3 * baseline
        // Resample this beat to templateN and normalize (mean 0, /amp).
        let resampled = Self.resample(beatSamples, to: templateN)
        let m = resampled.reduce(0, +) / Double(templateN)
        let norm = resampled.map { ($0 - m) / amp }
        if template.count == templateN {
            for i in 0..<templateN { template[i] = 0.7 * template[i] + 0.3 * norm[i] }
        } else {
            template = norm
        }
    }

    /// Whether we have enough to synthesize a plausible continuation.
    var isUsable: Bool { medianIbiMs != nil && template.count == templateN }

    /// Sample the template at phase 0…1 (linear interp, wrapping).
    func templateValue(atPhase phase: Double) -> Double {
        guard template.count == templateN else { return 0 }
        let p = phase - floor(phase)
        let x = p * Double(templateN)
        let i0 = Int(x) % templateN
        let i1 = (i0 + 1) % templateN
        let f = x - floor(x)
        return template[i0] * (1 - f) + template[i1] * f
    }

    func reset() {
        medianIbiMs = nil; amplitude = 1; baseline = 0
        template.removeAll(); ibis.removeAll()
    }

    static func resample(_ xs: [Double], to n: Int) -> [Double] {
        guard xs.count > 1, n > 1 else { return [Double](repeating: xs.first ?? 0, count: n) }
        var out = [Double](repeating: 0, count: n)
        let scale = Double(xs.count - 1) / Double(n - 1)
        for i in 0..<n {
            let x = Double(i) * scale
            let i0 = Int(x), i1 = min(i0 + 1, xs.count - 1)
            let f = x - Double(i0)
            out[i] = xs[i0] * (1 - f) + xs[i1] * f
        }
        return out
    }
}
