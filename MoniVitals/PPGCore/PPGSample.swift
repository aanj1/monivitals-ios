//
//  PPGSample.swift
//  MoniVitals — PPGCore
//
//  Core value types for the calm-UX PPG subsystem. Self-contained (all types are
//  PPG-prefixed) so it never collides with the existing DSP pipeline.
//

import Foundation

/// One point on either the measured or the display stream.
/// `isReconstructed` is the load-bearing flag: reconstructed samples may drive the
/// on-screen waveform but must NEVER be fed to physiological inference as real data.
struct PPGSample: Equatable {
    var tUs: Double
    var value: Double
    var isReconstructed: Bool
    var quality: Double
}

/// The ONLY three states the production UI is ever allowed to show.
enum PPGUIState: Equatable {
    case measuring
    case adjustFinger
    case fingerRemoved
}

/// Coarse signal-quality band shown on the scope pill (Good / Fair / Poor).
/// Derived from the internal composite quality; drives the coaching copy and the
/// accuracy gate on the displayed BPM.
enum PPGQualityBand: Equatable {
    case good
    case fair
    case poor

    var label: String {
        switch self {
        case .good: return "Good signal"
        case .fair: return "Fair signal"
        case .poor: return "Poor signal"
        }
    }
}

/// Wellness stress / recovery band derived from HRV (RMSSD). NOT a medical readout —
/// higher RMSSD reads as more relaxed/recovered, lower as more tense. Personal + soft.
enum PPGStressBand: Equatable {
    case calm
    case balanced
    case tense

    var label: String {
        switch self {
        case .calm: return "Calm / Recovered"
        case .balanced: return "Balanced"
        case .tense: return "Tense"
        }
    }
}

/// Rich internal state. Never surfaced to the production UI (debug overlays only).
enum PPGInternalState: Equatable {
    case initializing
    case good
    case degraded
    case reconstructing
    case recovering
    case lost
    case noFinger

    /// The calm production mapping. Anything still "measuring-ish" reads as Measuring;
    /// only a genuine sustained loss or removal interrupts the user.
    var uiState: PPGUIState {
        switch self {
        case .initializing, .good, .degraded, .reconstructing, .recovering:
            return .measuring
        case .lost:
            return .adjustFinger
        case .noFinger:
            return .fingerRemoved
        }
    }
}
