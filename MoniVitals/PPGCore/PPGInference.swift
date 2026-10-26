//
//  PPGInference.swift
//  MoniVitals — PPGCore
//
//  Physiological inference (BP/HRV) MUST run on REAL signal only. This layer takes
//  a measured window + its quality and REFUSES when the window contains reconstructed
//  samples or the quality is too low. Where a Core ML model would plug in is marked.
//

import Foundation
#if canImport(CoreML)
import CoreML
#endif

struct PPGEstimate: Equatable {
    var systolic: Double?
    var diastolic: Double?
    var confidence: Double        // 0…1
    var usedRealSamplesOnly: Bool
}

/// Reasons an estimate was withheld — internal/debug, never user-facing copy.
enum PPGInferenceRejection: Equatable {
    case containsReconstructed
    case qualityTooLow
    case notEnoughData
}

protocol PPGInferenceModel {
    /// Return an estimate, or nil if the input isn't trustworthy.
    func estimate(realWindow: [PPGSample], quality: Double) -> PPGEstimate?
}

/// Core ML BP estimator placeholder. No `.mlmodel` bundled — this demonstrates the
/// GATING contract, not a trained model.
final class PPGBloodPressureEstimator: PPGInferenceModel {
    private let minQuality: Double
    private let minSamples: Int
    private(set) var lastRejection: PPGInferenceRejection?

    #if canImport(CoreML)
    /// Where a compiled Core ML model would live once trained:
    ///   private let model: MLModel? = try? MLModel(contentsOf: url)
    private let model: MLModel? = nil
    #endif

    init(minQuality: Double = 0.6, minSamples: Int = 256) {
        self.minQuality = minQuality
        self.minSamples = minSamples
    }

    func estimate(realWindow: [PPGSample], quality: Double) -> PPGEstimate? {
        // HARD GATE 1: never accept reconstructed samples as real physiology.
        if realWindow.contains(where: { $0.isReconstructed }) {
            lastRejection = .containsReconstructed
            return nil
        }
        // HARD GATE 2: quality floor.
        if quality < minQuality {
            lastRejection = .qualityTooLow
            return nil
        }
        // HARD GATE 3: enough real data.
        if realWindow.count < minSamples {
            lastRejection = .notEnoughData
            return nil
        }
        lastRejection = nil

        #if canImport(CoreML)
        if let _ = model {
            // TODO: featurize `realWindow` → MLMultiArray → model.prediction(...)
            // Return the model's systolic/diastolic here.
        }
        #endif

        // No trained model bundled: return a flagged, low-confidence placeholder so
        // callers can see the gating worked without pretending to have a reading.
        return PPGEstimate(systolic: nil, diastolic: nil,
                           confidence: 0, usedRealSamplesOnly: true)
    }
}
