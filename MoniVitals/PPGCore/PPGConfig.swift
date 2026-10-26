//
//  PPGConfig.swift
//  MoniVitals — PPGCore
//
//  Every tunable in one place. Defaults are production-sane; adjust here rather
//  than scattering magic numbers through the pipeline.
//

import Foundation

struct PPGConfig {
    /// When true, PPGDemoView / debug overlays may show internal states + sub-scores.
    /// MUST stay false in the production UI path.
    static var debugEnabled = false

    // MARK: Capture
    /// Locked capture frame rate (Hz). A fixed fs keeps the DSP time-base honest.
    var targetFps: Double = 30
    /// Fraction of the frame (centered) averaged as the ROI. 0.4 = central 40%.
    var roiFraction: Double = 0.4
    /// Seconds to let AE/AWB/focus settle before locking them.
    var settleSeconds: Double = 0.8
    /// Pixel value (0…255) at/above which a channel counts as clipped.
    var clipLevel: Double = 250

    // MARK: Pulse band (Hz) ≈ 42…210 bpm
    var pulseLowHz: Double = 0.7
    var pulseHighHz: Double = 3.5

    // MARK: Quality thresholds (hysteresis — separate enter/exit)
    /// Enter "good" at/above this composite quality…
    var qualityGoodEnter: Double = 0.64
    /// …and only fall out of "good" below this (hysteresis gap avoids flicker).
    var qualityGoodExit: Double = 0.50
    /// Below this the signal is not usable → drives degraded→reconstructing.
    var qualityUsable: Double = 0.54
    /// EWMA smoothing factor for the composite quality (0…1, higher = snappier).
    var qualityEwmaAlpha: Double = 0.25

    // MARK: Gap / reconstruction timing (seconds)
    /// Gaps shorter than this are linearly interpolated (imperceptible).
    var interpolationMaxGap: Double = 0.15
    /// Max time we will synthesize continuation from history before giving up.
    var reconstructionMax: Double = 2.0
    /// Crossfade length when the real signal returns.
    var crossfadeSeconds: Double = 0.4
    /// Minimum time to dwell in a state before another transition (anti-flicker).
    var minDwell: Double = 0.30

    // MARK: Scan mode
    /// Fingertip contact (default) or palm hover. Presence thresholds below are
    /// resolved through the `presence*` accessors so the detector and the capture
    /// exposure gate follow the active mode.
    var scanMode: ScanMode = .finger

    // MARK: Finger presence (normalized red DC, 0…1)
    /// Red DC at/above this ⇒ a torch-lit fingertip is covering the lens.
    var fingerPresentEnter: Double = 0.55
    /// Sustained seconds at/above the enter threshold before declaring presence, so a
    /// single bright frame (e.g. a passing reflection) can't latch contact.
    var fingerPresentDwell: Double = 0.25
    /// Red DC must drop below this (sustained) to count as leaving.
    var fingerPresentExit: Double = 0.32
    /// Sustained seconds below the exit threshold before declaring removal.
    var fingerRemoveDwell: Double = 0.40

    // MARK: Palm presence (normalized red DC, 0…1)
    /// A palm hovering a few centimetres away reflects far less torch light than a
    /// pressed fingertip, so presence enters/exits at much lower red DC — and the
    /// clipped-pixel cue is meaningless (a hovering palm never saturates the sensor).
    var palmPresentEnter: Double = 0.22
    var palmPresentExit: Double = 0.10

    /// Presence thresholds for the ACTIVE scan mode.
    var presenceEnter: Double { scanMode == .palm ? palmPresentEnter : fingerPresentEnter }
    var presenceExit: Double { scanMode == .palm ? palmPresentExit : fingerPresentExit }
    /// Weight of the saturation cue in the presence probability (0 for palm).
    var presenceSatWeight: Double { scanMode == .palm ? 0.0 : 0.3 }

    // MARK: misc
    var usPerS: Double = 1_000_000.0
}
