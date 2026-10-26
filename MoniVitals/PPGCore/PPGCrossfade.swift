//
//  PPGCrossfade.swift
//  MoniVitals — PPGCore
//
//  When the real signal returns after reconstruction, blend from the synthesized
//  tail back to the measured signal over ~0.4 s so there's no visible jump. Also
//  estimates a baseline offset to align the two before blending.
//

import Foundation

final class PPGCrossfade {
    private let cfg: PPGConfig
    private var startedUs: Double?
    private var baselineOffset = 0.0       // added to real signal to match recon tail

    init(config: PPGConfig) { self.cfg = config }

    var isActive: Bool { startedUs != nil }

    /// Begin a crossfade. `reconTail` / `realHead` are the last synthesized value and
    /// the first real value, used to compute an alignment offset.
    func begin(at tUs: Double, reconTail: Double, realHead: Double) {
        startedUs = tUs
        baselineOffset = reconTail - realHead
    }

    /// Blend: returns the display value. `weight` ramps 0→1 (recon→real) over the
    /// crossfade window; the alignment offset decays to 0 alongside it.
    func value(at tUs: Double, reconValue: Double, realValue: Double) -> Double {
        guard let s = startedUs else { return realValue }
        let t = (tUs - s) / cfg.usPerS
        let w = clamp(t / max(0.05, cfg.crossfadeSeconds), 0, 1)
        if w >= 1 { startedUs = nil; return realValue }
        let alignedReal = realValue + baselineOffset * (1 - w)
        return reconValue * (1 - w) + alignedReal * w
    }

    func reset() { startedUs = nil; baselineOffset = 0 }
}
