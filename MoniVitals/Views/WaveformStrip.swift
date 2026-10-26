//
//  WaveformStrip.swift
//  MoniVitals
//
//  Live waveform strip rendered with Canvas. Reads directly from a non-reactive
//  WaveBuffer on a timer-driven redraw — high-rate sample data never goes through
//  @Published state, so the rest of SwiftUI is not re-rendered per sample. A local
//  @State tick advances ~30×/s and forces just this view's Canvas to repaint.
//
//  Used for the live ECG / PPG / BioZ strips (NOT Swift Charts, which is reserved for
//  recorded/static plots). The sample rate shown in each strip's title is derived from
//  the active source.
//

import SwiftUI

struct WaveformStrip: View {
    let title: String
    let buffer: WaveBuffer
    /// Window length shown, in seconds.
    var windowSec: Double = 4
    var color: Color = MV.ecg
    /// Optional second buffer drawn faintly behind (e.g. raw ECG under gated ECG).
    var underlay: WaveBuffer? = nil
    var underlayColor: Color = MV.inkMuted.opacity(0.4)
    var height: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tick: Int = 0
    /// Only redraw while the strip is on screen — TabView keeps off-screen tabs
    /// alive, so without this the 30 Hz repaint would run forever for every strip.
    @State private var isActive = false
    private let redraw = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ChipLabel(text: title, color: color)
                Spacer()
                if !hasSignal {
                    Text("warming up…")
                        .font(.caption2)
                        .foregroundStyle(MV.inkMuted)
                        .transition(.opacity)
                }
            }
            Canvas { ctx, size in
                _ = tick // depend on the tick so the Canvas repaints on every timer fire
                drawGrid(in: ctx, size: size)
                if let underlay {
                    draw(buffer: underlay, in: ctx, size: size, color: underlayColor,
                         lineWidth: 1, fill: false, leadingDot: false)
                }
                draw(buffer: buffer, in: ctx, size: size, color: color,
                     lineWidth: 1.6, fill: true, leadingDot: true)
            }
            .drawingGroup() // rasterize offscreen for crisper, cheaper anti-aliased strokes
            .frame(height: height)
            .background(
                LinearGradient(colors: [MV.bg, MV.surface],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: MV.rControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MV.rControl, style: .continuous)
                    .stroke(MV.separator, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) live waveform")
            .accessibilityValue(hasSignal ? "signal present" : "no signal yet")
        }
        .onReceive(redraw) { _ in if isActive { tick &+= 1 } }
        .onAppear { isActive = true }
        .onDisappear { isActive = false }
    }

    /// True once at least a couple of samples have arrived to draw a line.
    private var hasSignal: Bool { buffer.length > 1 }

    /// Faint grid: horizontal rows with an emphasized centre baseline, plus light
    /// vertical time divisions for a crisper oscilloscope read.
    private func drawGrid(in ctx: GraphicsContext, size: CGSize) {
        let rows = 4
        for r in 1..<rows {
            let y = size.height * CGFloat(r) / CGFloat(rows)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            let isCenter = r == rows / 2
            ctx.stroke(line,
                       with: .color(MV.separator.opacity(isCenter ? 0.9 : 0.45)),
                       style: StrokeStyle(lineWidth: isCenter ? 1 : 0.5))
        }
        // Vertical time divisions (one per second of the visible window).
        let cols = max(1, Int(windowSec.rounded()))
        if cols > 1 {
            for c in 1..<cols {
                let x = size.width * CGFloat(c) / CGFloat(cols)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(MV.separator.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 0.5))
            }
        }
    }

    private func draw(buffer: WaveBuffer, in ctx: GraphicsContext, size: CGSize,
                      color: Color, lineWidth: CGFloat, fill: Bool, leadingDot: Bool) {
        guard let latest = buffer.latestT() else { return }
        let windowUs = windowSec * DSPConstants.usPerS
        let from = latest - windowUs
        let (ts, vs) = buffer.window(from: from)
        guard ts.count > 1 else { return }

        // Auto-scale vertically using a robust 5–95th percentile range so a startup
        // transient (torch-on / finger-settle spike) can't flatten the real trace.
        // Falls back to min/max when there are too few samples for percentiles.
        var lo: Double, hi: Double
        if vs.count >= 10 {
            let sorted = vs.sorted()
            lo = sorted[Int(Double(sorted.count - 1) * 0.05)]
            hi = sorted[Int(Double(sorted.count - 1) * 0.95)]
        } else {
            lo = vs.min() ?? 0
            hi = vs.max() ?? 1
        }
        if !(hi > lo) { hi = lo + 1 }
        let margin = (hi - lo) * 0.12
        lo -= margin
        hi += margin

        let w = Double(size.width)
        let h = Double(size.height)
        func x(_ t: Double) -> Double { (t - from) / windowUs * w }
        func y(_ v: Double) -> Double { h - (v - lo) / (hi - lo) * h }

        // Build the trace path.
        var path = Path()
        path.move(to: CGPoint(x: x(ts[0]), y: y(vs[0])))
        for i in 1..<ts.count {
            path.addLine(to: CGPoint(x: x(ts[i]), y: y(vs[i])))
        }

        // Soft gradient fill under the trace (adds depth without shouting).
        if fill {
            var area = path
            area.addLine(to: CGPoint(x: x(ts[ts.count - 1]), y: h))
            area.addLine(to: CGPoint(x: x(ts[0]), y: h))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.20), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: h)))
        }

        // Subtle glow: a wide, faint stroke behind the crisp trace.
        ctx.stroke(path, with: .color(color.opacity(0.18)),
                   style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round, lineJoin: .round))
        // Crisp anti-aliased trace.
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        // A "leading edge" dot at the newest sample, with a gentle halo (pause on reduce-motion).
        if leadingDot, let lt = ts.last, let lv = vs.last {
            let p = CGPoint(x: x(lt), y: y(lv))
            let pulse = reduceMotion ? 1.0 : (0.85 + 0.15 * sin(Double(tick) * 0.4))
            let halo = 7.0 * pulse
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                     with: .color(color.opacity(0.18)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                     with: .color(color))
        }
    }
}
