//
//  SignalQuality.swift
//  MoniVitals
//
//  Works out whether a fingertip is really covering the camera and how clean the
//  pulse looks. Under the torch a covered fingertip pins the RED channel bright
//  and nearly flat (saturated), while the GREEN channel carries the pulsatile
//  ripple. So the ingredients read from different channels:
//   • brightness — a covered lens over the torch reads bright (RED, DC),
//   • perfusion  — a real pulse ripples the GREEN channel (AC/DC),
//   • stability  — a steady hold means low frame-to-frame jitter in the baseline.
//
//  Pure and testable: the classifier is a plain function over paired windows.
//

import Foundation

/// A single 0…100 quality score plus the boolean "is a fingertip covering it".
struct SignalQualityScore: Equatable {
    /// 0…100 overall quality.
    var quality: Int
    /// True when a fingertip appears to be covering the camera.
    var contact: Bool
}

enum SignalQuality {

    /// Classify contact + quality from paired brightness (red) and pulse (green)
    /// windows. Brightness/contact come from the RED channel (a covered lens over
    /// the torch pins it bright); perfusion comes from the GREEN channel, which
    /// carries the pulse even when red is saturated flat.
    ///
    /// - Parameters:
    ///   - brightness: recent red-channel samples (chronological), for DC/contact.
    ///   - pulse: recent green-channel samples (chronological), for the AC ripple.
    ///   - maxLevel: the value that counts as "fully bright" (default 255).
    static func classify(brightness bright: [Double], pulse: [Double],
                         maxLevel: Double = 255) -> SignalQualityScore {
        guard bright.count >= 4, pulse.count >= 4 else {
            return SignalQualityScore(quality: 0, contact: false)
        }

        let mb = mean(bright)

        // Brightness: a fingertip over the torch pins the red channel high.
        let brightness = clamp(mapRange(mb, maxLevel * 0.4, maxLevel * 0.9, 0, 100), 0, 100)

        // Perfusion: the living pulse ripples the GREEN channel by ~0.1–3% of its
        // mean. Red saturates flat under the torch, so it can't show this — green can.
        let mp = mean(pulse)
        let ac = mp > 0 ? stddev(pulse) / mp : 0
        let perfusion = clamp(mapRange(ac, 0.001, 0.03, 0, 100), 0, 100)

        // Stability: penalise wild frame-to-frame jumps in the bright baseline
        // (movement / regripping), read off the DC (red) channel.
        var jumpSum = 0.0
        for i in 1..<bright.count { jumpSum += abs(bright[i] - bright[i - 1]) }
        let jump = mb > 0 ? (jumpSum / Double(bright.count - 1)) / mb : 1
        let stability = clamp(100 * (1 - clamp(jump / 0.05, 0, 1)), 0, 100)

        let quality = Int((0.35 * brightness + 0.45 * perfusion + 0.2 * stability).rounded())
        // Contact: lens genuinely covered (bright red) AND at least a little green pulse.
        let contact = brightness >= 55 && perfusion >= 12
        return SignalQualityScore(quality: quality, contact: contact)
    }
}

/// Rolling signal-quality reporter fed the red + green samples as they arrive.
/// Smooths the 0…100 quality so the on-screen bar doesn't jitter frame to frame.
final class SignalQualityReporter {
    private var bright: [Double] = []
    private var pulse: [Double] = []
    private let cap: Int
    private var smoothed: Double?

    /// - Parameter fs: expected sample rate; each window holds ~2 s.
    init(fs: Double) {
        self.cap = max(8, Int((fs * 2.0).rounded()))
    }

    func push(red redSample: Double, green greenSample: Double) {
        bright.append(redSample)
        if bright.count > cap { bright.removeFirst(bright.count - cap) }
        pulse.append(greenSample)
        if pulse.count > cap { pulse.removeFirst(pulse.count - cap) }
    }

    func score() -> SignalQualityScore {
        let raw = SignalQuality.classify(brightness: bright, pulse: pulse)
        // EWMA-smooth the quality number; contact stays responsive (unsmoothed).
        let s = smoothed.map { 0.7 * $0 + 0.3 * Double(raw.quality) } ?? Double(raw.quality)
        smoothed = s
        return SignalQualityScore(quality: Int(s.rounded()), contact: raw.contact)
    }

    /// Non-mutating look at the current raw quality/contact without touching the
    /// EWMA smoothing state. Used by the high-rate ingest path to gate beats on
    /// the *current* signal instead of a value left over from the last snapshot.
    func peek() -> SignalQualityScore {
        SignalQuality.classify(brightness: bright, pulse: pulse)
    }

    func reset() {
        bright.removeAll(keepingCapacity: true)
        pulse.removeAll(keepingCapacity: true)
        smoothed = nil
    }
}
