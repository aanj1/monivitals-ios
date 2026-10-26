//
//  PPGDemoView.swift
//  MoniVitals — PPGCore
//
//  Self-contained demo of the calm-UX PPG subsystem (NOT wired into RootView).
//  Renders the continuous displayPPG and shows ONLY the three production states.
//  Internal states / sub-scores / reconstruction markers appear solely in the
//  debug overlay gated on PPGConfig.debugEnabled.
//

import SwiftUI

struct PPGDemoView: View {
    @StateObject private var engine = PPGEngine()

    var body: some View {
        VStack(spacing: 16) {
            Text("MoniVitals — Pulse")
                .font(.headline)

            // The single calm production status line.
            Text(statusText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusColor)
                .animation(.easeInOut(duration: 0.25), value: engine.uiState)

            waveform
                .frame(height: 160)
                .background(Color(white: 0.97))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if let bpm = engine.bpm {
                Text("\(Int(bpm.rounded())) bpm").font(.title2.monospacedDigit())
            } else {
                Text("— bpm").font(.title2).foregroundStyle(.secondary)
            }

            if let msg = engine.cameraUnavailableMessage {
                Text(msg).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Developer-only diagnostics — never part of the production path.
            if PPGConfig.debugEnabled {
                debugOverlay
            }

            Spacer()
        }
        .padding()
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    // Only the 3 allowed strings — no "weak signal / low confidence / recovering / …".
    private var statusText: String {
        switch engine.uiState {
        case .measuring: return "Measuring"
        case .adjustFinger: return "Adjust finger"
        case .fingerRemoved: return "Finger removed"
        }
    }

    private var statusColor: Color {
        switch engine.uiState {
        case .measuring: return .green
        case .adjustFinger: return .orange
        case .fingerRemoved: return .red
        }
    }

    private var waveform: some View {
        Canvas { ctx, size in
            let samples = engine.displaySamples
            guard samples.count > 1 else { return }
            let vs = samples.map { $0.value }
            var lo = vs.min() ?? 0, hi = vs.max() ?? 1
            if !(hi > lo) { hi = lo + 1 }
            let n = samples.count
            func x(_ i: Int) -> Double { Double(i) / Double(n - 1) * size.width }
            func y(_ v: Double) -> Double { size.height - (v - lo) / (hi - lo) * size.height }

            // Base trace.
            var path = Path()
            path.move(to: CGPoint(x: x(0), y: y(vs[0])))
            for i in 1..<n { path.addLine(to: CGPoint(x: x(i), y: y(vs[i]))) }
            ctx.stroke(path, with: .color(.pink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // Reconstructed segments highlighted ONLY in debug.
            if PPGConfig.debugEnabled {
                var rp = Path()
                for i in 1..<n where samples[i].isReconstructed {
                    rp.move(to: CGPoint(x: x(i - 1), y: y(vs[i - 1])))
                    rp.addLine(to: CGPoint(x: x(i), y: y(vs[i])))
                }
                ctx.stroke(rp, with: .color(.blue), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            }
        }
    }

    private var debugOverlay: some View {
        let d = engine.debug
        return VStack(alignment: .leading, spacing: 2) {
            Text("internal: \(String(describing: d.internalState))")
            Text(String(format: "quality: %.2f  finger: %.2f", d.quality.composite, d.fingerProbability))
            Text(String(format: "period: %.2f  acdc: %.2f  motion: %.2f",
                        d.quality.periodicity, d.quality.acdc, d.quality.motion))
            Text(verbatim: "recon: \(d.reconstructing) \(String(format: "%.1fs", d.reconElapsed))  xfade: \(d.crossfading)")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
