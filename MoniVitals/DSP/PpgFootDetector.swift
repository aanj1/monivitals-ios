//
//  PpgFootDetector.swift
//  MoniVitals
//
//  PPG pulse-foot detector (intersecting tangents).
//
//  Light low-pass → first derivative → detect each pulse's maximum-upslope point
//  (adaptive peak detection on the derivative with a refractory) → the foot is the
//  intersection of the horizontal line at the pre-upstroke minimum and the tangent
//  through the max-upslope point. See docs/DSP.md.
//
//  Ported line-for-line from web/src/dsp/ppgFoot.ts.
//

import Foundation

final class PpgFootDetector {
    private let lp: MovingAverage
    private let refractoryUs: Double
    private let historyUs = 1_000_000.0
    private let learnUntilSample: Int

    // `nil` mirrors the TS `NaN` "not yet seen" sentinel for the previous sample.
    private var prevY: Double? = nil
    private var prevT: Double? = nil

    // Local-max tracking on the slope.
    private var lastSlope = 0.0
    private var lastSlopeT = 0.0
    private var lastSlopeY = 0.0
    private var rising = false

    private var spk = 0.0
    private var npk = 0.0
    private var learned = false
    private var learnMax = 0.0
    private var learnSum = 0.0
    private var learnCount = 0

    private var sampleCount = 0
    private var lastFootUs = -Double.infinity

    // History of smoothed samples for the pre-upstroke minimum search.
    private var hY: [Double]
    private var hT: [Double]
    private var head = 0
    private var filled = 0

    init(fs: Double, learnMs: Double = 1500) {
        // Minimum width 3: at fs ≤ 50 the 30 ms window rounds to a single sample,
        // which is no smoothing at all.
        self.lp = MovingAverage(width: max(3, Int((fs * 0.03).rounded())))
        self.refractoryUs = (DSPConstants.qrsRefractoryMs / 1000) * 1e6
        self.learnUntilSample = Int((learnMs / 1000 * fs).rounded())
        let cap = Int((self.historyUs / 1e6 * fs).rounded(.up)) + 8
        self.hY = Array(repeating: 0.0, count: cap)
        self.hT = Array(repeating: 0.0, count: cap)
    }

    /// Feed one PPG (green) sample with its device timestamp (µs). Returns a foot time or nil.
    func process(_ green: Double, _ tUs: Double) -> Double? {
        let y = lp.process(green)
        pushHistory(y, tUs)

        var slope = 0.0
        if let py = prevY, let pt = prevT, tUs > pt {
            slope = (y - py) / (tUs - pt)
        }
        prevY = y
        prevT = tUs

        sampleCount += 1
        if !learned {
            if slope > 0 {
                learnMax = Swift.max(learnMax, slope)
                learnSum += slope
                learnCount += 1
            }
            if sampleCount >= learnUntilSample {
                spk = learnMax
                npk = learnCount > 0 ? learnSum / Double(learnCount) : 0
                learned = true
            }
            lastSlope = slope
            lastSlopeT = tUs
            lastSlopeY = y
            return nil
        }

        // Search-back: when no beat has been accepted for ~2 refractory periods the
        // threshold is probably pinned above the real pulse (spk seeded from a
        // placement transient never decays on its own — rejected upstrokes only
        // move npk). Decay the signal-peak estimate toward the noise floor each
        // sample until beats start clearing the threshold again.
        if tUs - lastFootUs > refractoryUs * 2 {
            spk = 0.95 * spk + 0.05 * npk
        }

        var result: Double? = nil
        if slope > lastSlope {
            rising = true
        } else if slope < lastSlope && rising {
            rising = false
            result = evaluateUpstroke(lastSlope, lastSlopeT, lastSlopeY)
        }
        lastSlope = slope
        lastSlopeT = tUs
        lastSlopeY = y
        return result
    }

    private func threshold() -> Double {
        npk + 0.3 * (spk - npk)
    }

    private func evaluateUpstroke(_ slope: Double, _ tS: Double, _ yS: Double) -> Double? {
        if slope <= 0 || slope <= threshold() {
            npk = 0.125 * Swift.max(0, slope) + 0.875 * npk
            return nil
        }
        spk = 0.125 * slope + 0.875 * spk
        let foot = computeFoot(slope, tS, yS)
        if foot - lastFootUs >= refractoryUs {
            lastFootUs = foot
            return foot
        }
        return nil
    }

    /// Intersecting tangents: foot where the tangent at max-slope meets the prior minimum.
    private func computeFoot(_ slope: Double, _ tS: Double, _ yS: Double) -> Double {
        // Pre-upstroke minimum of the smoothed signal within the search-back window.
        let lo = tS - refractoryUs * 2
        var yMin = yS
        let cap = hY.count
        for i in 0..<filled {
            let idx = ((head - 1 - i) % cap + cap) % cap
            let t = hT[idx]
            if t > tS { continue }
            if t < lo { break }
            if hY[idx] < yMin { yMin = hY[idx] }
        }
        // t_foot = t_s + (y_min - y_s) / slope (slope > 0, y_min <= y_s ⇒ foot precedes t_s).
        let foot = tS + (yMin - yS) / slope
        return Swift.min(foot, tS)
    }

    private func pushHistory(_ y: Double, _ t: Double) {
        hY[head] = y
        hT[head] = t
        head = (head + 1) % hY.count
        if filled < hY.count { filled += 1 }
    }
}
