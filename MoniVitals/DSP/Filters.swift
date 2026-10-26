//
//  Filters.swift
//  MoniVitals
//
//  Streaming filter primitives shared by the detectors. Stateful objects process one
//  sample at a time so they work identically on live BLE data and on recorded replay.
//
//  Ported line-for-line from web/src/dsp/filters.ts.
//

import Foundation

// MARK: - Biquad

/// Biquad coefficients (normalized so a0 = 1).
struct BiquadCoeffs {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
}

/// 2nd-order Butterworth band-pass coefficients (RBJ cookbook) for the given
/// center/bandwidth derived from low/high cutoffs.
func bandpassCoeffs(lowHz: Double, highHz: Double, fs: Double) -> BiquadCoeffs {
    // Guard degenerate inputs, mirroring PPGBiquad: a zero bandwidth (lowHz == highHz)
    // drives q to infinity → alpha 0 → a silent identity filter, and a center past
    // Nyquist (w0 > pi, too-low fs) folds the response. These clamps are no-ops for the
    // normal fixed bands.
    let f0 = max(0.01, (lowHz * highHz).squareRoot())
    let bw = max(0.01, highHz - lowHz)
    let w0 = min(Double.pi - 1e-6, (2 * Double.pi * f0) / fs)
    let cosw0 = cos(w0)
    let sinw0 = sin(w0)
    // Bandwidth-based Q, clamped to a sane floor so a wide/degenerate band can't zero it.
    let q = max(0.3, f0 / bw)
    let alpha = sinw0 / (2 * q)
    let a0 = 1 + alpha
    return BiquadCoeffs(
        b0: alpha / a0,
        b1: 0,
        b2: -alpha / a0,
        a1: (-2 * cosw0) / a0,
        a2: (1 - alpha) / a0
    )
}

/// Direct Form II transposed biquad, processed one sample at a time.
final class Biquad {
    private var z1 = 0.0
    private var z2 = 0.0
    private let c: BiquadCoeffs

    init(_ coeffs: BiquadCoeffs) {
        self.c = coeffs
    }

    static func bandpass(lowHz: Double, highHz: Double, fs: Double) -> Biquad {
        Biquad(bandpassCoeffs(lowHz: lowHz, highHz: highHz, fs: fs))
    }

    func process(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    func reset() {
        z1 = 0
        z2 = 0
    }
}

// MARK: - Five-point derivative

/// 5-point derivative (Pan–Tompkins): `y[n] = (2x[n] + x[n-1] − x[n-3] − 2x[n-4]) / 8`.
final class FivePointDerivative {
    private var x: [Double] = [0, 0, 0, 0, 0]

    func process(_ sample: Double) -> Double {
        x[4] = x[3]
        x[3] = x[2]
        x[2] = x[1]
        x[1] = x[0]
        x[0] = sample
        return (2 * x[0] + x[1] - x[3] - 2 * x[4]) / 8
    }
}

// MARK: - Moving average

/// Causal moving-window average over a fixed number of samples.
final class MovingAverage {
    let width: Int
    private var buf: [Double]
    private var idx = 0
    private var filled = 0
    private var sum = 0.0

    init(width: Int) {
        self.width = width
        self.buf = Array(repeating: 0.0, count: max(1, width))
    }

    func process(_ x: Double) -> Double {
        let w = buf.count
        sum -= buf[idx]
        buf[idx] = x
        sum += x
        idx = (idx + 1) % w
        if filled < w { filled += 1 }
        return sum / Double(filled)
    }
}
