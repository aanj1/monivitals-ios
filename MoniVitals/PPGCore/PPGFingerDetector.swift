//
//  PPGFingerDetector.swift
//  MoniVitals — PPGCore
//
//  Finger-PRESENCE detection, deliberately independent of pulse amplitude. A
//  torch-lit fingertip pins the RED channel bright and near-saturated; ambient/no
//  finger looks very different. Hysteresis + a dwell timer mean a momentary dip in
//  pulse strength is NEVER mistaken for the finger leaving.
//

import Foundation

final class PPGFingerDetector {
    private let cfg: PPGConfig
    private var redDcEwma: Double?          // smoothed red DC, 0…255
    private var present = false
    private var aboveSinceUs: Double?       // when red first rose above enter
    private var belowSinceUs: Double?       // when red first dropped below exit

    init(config: PPGConfig) { self.cfg = config }

    /// 0…1 probability the finger is covering the lens (smoothed, presence-biased).
    private(set) var probability: Double = 0

    /// Strong evidence the finger has actually left (sustained red collapse).
    private(set) var removedEvidence = false

    func update(red: Double, satFraction: Double, tUs: Double) {
        let dc = redDcEwma.map { $0 + 0.1 * (red - $0) } ?? red
        redDcEwma = dc
        let norm = clamp(dc / 255.0, 0, 1)
        // A covered fingertip is bright AND fairly saturated; blend both cues. In
        // palm mode the saturation weight is 0 (a hovering palm never clips), so
        // presence rides on brightness alone — normalized against the palm enter
        // threshold so a dimmer-but-present palm still reads near 1.
        let satW = cfg.presenceSatWeight
        if satW > 0 {
            probability = clamp((1 - satW) * norm + satW * satFraction, 0, 1)
        } else {
            probability = clamp(norm / max(0.01, cfg.presenceEnter * 2), 0, 1)
        }

        // Hysteresis on presence — with a symmetric ENTRY dwell so one bright frame
        // can't latch contact (mirrors the removal dwell).
        if !present {
            if norm >= cfg.presenceEnter {
                if aboveSinceUs == nil { aboveSinceUs = tUs }
                if let since = aboveSinceUs, (tUs - since) >= cfg.fingerPresentDwell * cfg.usPerS {
                    present = true; belowSinceUs = nil; aboveSinceUs = nil
                }
            } else {
                aboveSinceUs = nil
            }
        } else if norm < cfg.presenceExit {
            if belowSinceUs == nil { belowSinceUs = tUs }
        } else if norm >= cfg.presenceExit {
            belowSinceUs = nil
        }

        // Removal requires the drop to PERSIST (dwell) — not a brief dip.
        if let since = belowSinceUs, (tUs - since) >= cfg.fingerRemoveDwell * cfg.usPerS {
            present = false
            removedEvidence = true
            belowSinceUs = nil
        } else {
            removedEvidence = false
        }
    }

    var isPresent: Bool { present }

    func reset() {
        redDcEwma = nil; present = false; aboveSinceUs = nil; belowSinceUs = nil
        probability = 0; removedEvidence = false
    }
}
