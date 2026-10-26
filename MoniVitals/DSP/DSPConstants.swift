//
//  DSPConstants.swift
//  MoniVitals
//
//  Fixed constants for the pulse (PPG) signal processing. These describe the
//  frequency bands and reporting windows the camera pipeline uses. Movement
//  sensitivity is user-adjustable in Settings; the rest are fixed.
//

import Foundation

enum DSPConstants {
    // Pulse band-pass (heart-rate band): ~0.7–3.5 Hz ≈ 42–210 bpm.
    static let pulseBpLowHz = 0.7
    static let pulseBpHighHz = 3.5

    // Respiratory band: 0.1–0.5 Hz ≈ 6–30 breaths/min.
    static let respBpLowHz = 0.1
    static let respBpHighHz = 0.5

    // Beat spacing / refractory (used by the pulse-foot detector).
    static let qrsRefractoryMs = 300.0

    // Heart-rate reporting.
    static let hrMedianN = 5
    static let hrMinBpm = 40.0
    static let hrMaxBpm = 210.0

    // Respiratory-rate reporting.
    static let respMinBpm = 6.0
    static let respMaxBpm = 30.0

    // Minimum smoothed signal quality (0…100) before fresh HR / breathing / HRV
    // estimates are pushed. Below this the last good values are held instead of
    // computing on noise — a noisy window otherwise surfaces false beats (e.g. a
    // 133 bpm spike on a "poor signal" hold).
    static let minQualityForVitals = 40

    // Movement gating for HRV: movement level (0…100 scale, matching
    // MotionMonitor.movement) above which a window is too shaky to trust HRV.
    // Raised to 55 so normal handheld camera use still yields HRV — at 24 a phone
    // held in the hand almost always exceeded it, so HRV never appeared.
    // User-adjustable in Settings.
    static let motionThresh = 55.0

    /// Microseconds per second — used everywhere we convert time.
    static let usPerS = 1_000_000.0
}
