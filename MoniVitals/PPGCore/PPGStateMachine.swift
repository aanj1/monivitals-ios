//
//  PPGStateMachine.swift
//  MoniVitals — PPGCore
//
//  Drives the internal state from quality + finger-presence + timers, with
//  hysteresis (separate enter/exit thresholds + a minimum dwell) so borderline
//  signal never flickers the (mapped) production UI.
//

import Foundation

struct PPGStateInputs {
    var quality: Double
    var fingerPresent: Bool
    var removedEvidence: Bool
    var reconElapsed: Double      // seconds since reconstruction began
    var tUs: Double
}

final class PPGStateMachine {
    private let cfg: PPGConfig
    private(set) var state: PPGInternalState = .initializing
    private var enteredUs: Double = 0

    init(config: PPGConfig) { self.cfg = config }

    private func go(_ s: PPGInternalState, _ tUs: Double) {
        guard s != state else { return }
        state = s
        enteredUs = tUs
    }

    private func dwellOK(_ tUs: Double) -> Bool {
        (tUs - enteredUs) >= cfg.minDwell * cfg.usPerS
    }

    @discardableResult
    func update(_ inp: PPGStateInputs) -> PPGInternalState {
        let t = inp.tUs
        let q = inp.quality

        // Removal is prompt + overrides everything (strong evidence only).
        if inp.removedEvidence {
            go(.noFinger, t)
            return state
        }

        switch state {
        case .noFinger:
            if inp.fingerPresent { go(.initializing, t) }

        case .initializing:
            if q >= cfg.qualityGoodEnter { go(.good, t) }

        case .good:
            if q < cfg.qualityGoodExit, dwellOK(t) { go(.degraded, t) }

        case .degraded:
            if q >= cfg.qualityGoodEnter { go(.good, t) }
            else if q < cfg.qualityUsable, inp.fingerPresent, dwellOK(t) {
                go(.reconstructing, t)
            }

        case .reconstructing:
            if q >= cfg.qualityUsable { go(.recovering, t) }
            else if (t - enteredUs) >= cfg.reconstructionMax * cfg.usPerS {
                go(.lost, t)                 // give up extrapolating → UI: Adjust finger
            }

        case .recovering:
            if q >= cfg.qualityGoodEnter { go(.good, t) }
            // Hysteresis against reconstructing↔recovering flip-flop: entry was at
            // qualityUsable, so only fall back once quality drops clearly below it
            // (goodExit < usable) AND the minimum dwell has passed — otherwise a
            // borderline signal bounces between the two states every frame.
            else if q < cfg.qualityGoodExit, dwellOK(t) { go(.reconstructing, t) }

        case .lost:
            // Finger back on the lens → re-acquire, instead of staying pinned on
            // "Adjust finger" when a lightly-held finger keeps quality just under usable.
            if inp.fingerPresent { go(.initializing, t) }
            else if q >= cfg.qualityUsable { go(.recovering, t) }
        }
        return state
    }

    var uiState: PPGUIState { state.uiState }

    func reset() { state = .initializing; enteredUs = 0 }
}
