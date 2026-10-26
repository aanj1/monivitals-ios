//
//  PPGDebug.swift
//  MoniVitals — PPGCore
//
//  Developer-only diagnostics. Surfaced ONLY when PPGConfig.debugEnabled — never in
//  the production UI path.
//

import Foundation

struct PPGDebugSnapshot: Equatable {
    var internalState: PPGInternalState
    var uiState: PPGUIState
    var quality: PPGQualityScore
    var fingerProbability: Double
    var fingerPresent: Bool
    var reconstructing: Bool
    var reconElapsed: Double
    var crossfading: Bool
    var bpm: Double?
    var measuredFs: Double

    static let empty = PPGDebugSnapshot(
        internalState: .initializing, uiState: .measuring, quality: .zero,
        fingerProbability: 0, fingerPresent: false, reconstructing: false,
        reconElapsed: 0, crossfading: false, bpm: nil, measuredFs: 0)
}
