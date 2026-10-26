//
//  PPGReconstructor.swift
//  MoniVitals — PPGCore
//
//  Keeps the DISPLAY waveform continuous during a brief dropout. Tiny gaps → linear
//  interpolation; longer gaps (up to reconstructionMax) → synthesize from the recent
//  clean template at the recent period, phase-continuous from the last real sample.
//  It holds the recent rate — it never invents a new heart rate. Every sample it
//  returns is flagged `isReconstructed = true`.
//

import Foundation

final class PPGReconstructor {
    private let cfg: PPGConfig
    private var phase = 0.0                 // 0…1 within a beat
    private var startedUs: Double?          // when this reconstruction run began
    private var periodS: Double = 0.8

    init(config: PPGConfig) { self.cfg = config }

    var isActive: Bool { startedUs != nil }

    /// Elapsed reconstruction time (seconds), or 0 when inactive.
    func elapsed(_ tUs: Double) -> Double {
        guard let s = startedUs else { return 0 }
        return (tUs - s) / cfg.usPerS
    }

    /// Begin (or continue) synthesizing. Aligns the starting phase so the first
    /// reconstructed value matches `lastValue` — no visible step.
    ///
    /// Everything here lives in the FILTERED (zero-centred) domain the display
    /// stream uses: the template is built from band-passed beat samples, so the
    /// synthesized wave rides on baseline 0. (`history.baseline` tracks the raw
    /// green DC — adding it here stepped the display by ~two orders of magnitude.)
    func begin(at tUs: Double, lastValue: Double, history: PPGHistory) {
        guard startedUs == nil else { return }
        startedUs = tUs
        periodS = history.periodS ?? 0.8
        // Search the phase whose template value best matches the last displayed
        // sample (both zero-centred, normalized by the recent amplitude).
        guard history.isUsable else { phase = 0; return }
        var bestPhase = 0.0, bestErr = Double.infinity
        let target = lastValue / max(1e-6, history.amplitude)
        var p = 0.0
        while p < 1.0 {
            let err = abs(history.templateValue(atPhase: p) - target)
            if err < bestErr { bestErr = err; bestPhase = p }
            p += 1.0 / 64.0
        }
        phase = bestPhase
    }

    /// Produce the next reconstructed sample value at `tUs` (advance by dt seconds).
    /// Zero-centred like the filtered display stream — see `begin`.
    func next(tUs: Double, dtS: Double, history: PPGHistory) -> Double {
        periodS = history.periodS ?? periodS
        // Wrap phase to [0,1) on update so it can't grow unbounded over a long
        // reconstruction and lose float precision. Equivalent for the template
        // (which already does phase - floor(phase)) and the period-1 sine fallback.
        phase = (phase + dtS / max(0.2, periodS)).truncatingRemainder(dividingBy: 1.0)
        let shape = history.isUsable ? history.templateValue(atPhase: phase) : sin(2 * .pi * phase)
        return history.amplitude * shape
    }

    func end() { startedUs = nil }

    func reset() { startedUs = nil; phase = 0; periodS = 0.8 }

    /// Linear interpolation for sub-interpolationMaxGap holes.
    static func interpolate(from a: Double, to b: Double, frac: Double) -> Double {
        a + (b - a) * clamp(frac, 0, 1)
    }
}
