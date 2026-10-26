//
//  PPGPulseStrip.swift
//  MoniVitals
//
//  Cardiographer-style oscilloscope card for CAMERA mode. Renders PPGEngine's calm
//  display stream (kept visually continuous through brief dips via interpolation /
//  short-gap reconstruction) on a dark scope, with a Good/Fair/Poor quality pill, a
//  raw "red NNN" readout, and a small live camera ROI thumbnail. Reconstructed
//  segments look identical to real in production; the distinction lives only in debug.
//

import SwiftUI

struct PPGPulseStrip: View {
    @ObservedObject var engine: PPGEngine
    var height: CGFloat = 190

    private let scopeBG = Color(red: 0.03, green: 0.05, blue: 0.06)
    private let scopeGreen = Color(red: 0.22, green: 0.87, blue: 0.52)

    private var bandColor: Color {
        switch engine.qualityBand {
        case .good: return scopeGreen
        case .fair: return Color(red: 0.95, green: 0.62, blue: 0.11)
        case .poor: return Color(red: 0.94, green: 0.29, blue: 0.31)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(scopeBG)

            Canvas { ctx, size in draw(ctx, size) }
                .padding(.top, 40).padding(.bottom, 10).padding(.horizontal, 10)

            VStack {
                HStack(alignment: .top) {
                    qualityPill
                    Spacer()
                    HStack(spacing: 8) {
                        Text("red \(engine.redLevel)")
                            .font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.55))
                        thumbnail
                    }
                }
                Spacer()
            }
            .padding(10)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live pulse waveform")
        .accessibilityValue(engine.qualityBand.label)
    }

    private var qualityPill: some View {
        HStack(spacing: 6) {
            Circle().fill(bandColor).frame(width: 7, height: 7)
            Text(engine.qualityBand.label)
                .font(.caption.weight(.semibold)).foregroundStyle(bandColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(bandColor.opacity(0.16)))
    }

    @ViewBuilder private var thumbnail: some View {
        if let cg = engine.previewImage {
            Image(decorative: cg, scale: 1, orientation: .right)
                .resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay(Circle().stroke(scopeGreen, lineWidth: 2))
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        // Faint oscilloscope grid.
        let rows = 4, cols = 6
        for r in 1..<rows {
            let y = size.height * CGFloat(r) / CGFloat(rows)
            var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y))
            ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        }
        for c in 1..<cols {
            let x = size.width * CGFloat(c) / CGFloat(cols)
            var p = Path(); p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height))
            ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 0.5)
        }

        let s = engine.displaySamples
        guard s.count > 1 else { return }

        // Robust autoscale (5–95th percentile) so a transient can't flatten the trace,
        // tight enough that systolic peaks + the dicrotic notch stay visible.
        let vals = s.map(\.value).sorted()
        func pct(_ p: Double) -> Double { vals[min(vals.count - 1, max(0, Int(Double(vals.count - 1) * p)))] }
        var lo = vals.count >= 10 ? pct(0.05) : (vals.first ?? 0)
        var hi = vals.count >= 10 ? pct(0.95) : (vals.last ?? 1)
        if !(hi > lo) { hi = lo + 1 }
        let m = (hi - lo) * 0.14; lo -= m; hi += m

        let t0 = s.first!.tUs, t1 = s.last!.tUs, span = max(1, t1 - t0)
        func x(_ t: Double) -> Double { (t - t0) / span * size.width }
        func y(_ v: Double) -> Double { size.height - (v - lo) / (hi - lo) * size.height }

        var path = Path(); path.move(to: .init(x: x(s[0].tUs), y: y(s[0].value)))
        for i in 1..<s.count { path.addLine(to: .init(x: x(s[i].tUs), y: y(s[i].value))) }

        var fill = path
        fill.addLine(to: .init(x: x(s[s.count - 1].tUs), y: size.height))
        fill.addLine(to: .init(x: x(s[0].tUs), y: size.height)); fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [scopeGreen.opacity(0.22), scopeGreen.opacity(0.02)]),
            startPoint: .init(x: 0, y: 0), endPoint: .init(x: 0, y: size.height)))

        ctx.stroke(path, with: .color(scopeGreen.opacity(0.20)),
                   style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .color(scopeGreen),
                   style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }
}
