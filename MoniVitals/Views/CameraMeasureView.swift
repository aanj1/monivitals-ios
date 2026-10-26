//
//  CameraMeasureView.swift
//  MoniVitals
//
//  Cardiographer-style camera measurement: a dark oscilloscope scope, a big BPM
//  numeral that is accuracy-gated (shows "— —" on a poor / unsettled signal rather
//  than a wrong number), a coaching line, and Flash / Recalibrate / Stop controls.
//  Reads PPGEngine directly so it updates smoothly; the recording/save flow stays
//  in MeasureView's save card below. Camera mode only — device mode is untouched.
//

import SwiftUI

struct CameraMeasureView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var engine: PPGEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paused = false
    @State private var beat = false

    private let scopeGreen = Color(red: 0.22, green: 0.87, blue: 0.52)

    /// Short "do this" prompt matching the active scan style.
    private var placePrompt: String {
        model.scanMode == .palm ? "Show palm" : "Place finger"
    }

    var body: some View {
        let live = model.liveMetrics
        let liveBpm = live?.hrBpm ?? engine.bpm
        VStack(alignment: .leading, spacing: MV.s16) {
            ZStack {
                PPGPulseStrip(engine: engine, height: 190)
                if paused {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.55))
                    Text("Paused").font(.headline).foregroundStyle(.white)
                }
            }

            // Big accuracy-gated BPM with a gently pulsing heart.
            HStack(spacing: MV.s16) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 40)).foregroundStyle(MV.magenta)
                    .scaleEffect(beat && !reduceMotion ? 1.12 : 1.0)
                    .task(id: bpmBucket(liveBpm)) { await restartBeat() }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // numericText only interpolates digits, so applying it while the
                    // placeholder ("— —") is showing animates oddly. Use it only for the
                    // numeric readout; render the placeholder with a plain transition.
                    Text(liveBpm == nil ? "— —" : Fmt.bpm(liveBpm))
                        .font(MV.number(52)).foregroundStyle(MV.ink)
                        .contentTransition(liveBpm == nil ? .identity : .numericText())
                        .monospacedDigit()
                    Text("BPM").font(.title3.weight(.semibold)).foregroundStyle(MV.inkMuted)
                }
                Spacer(minLength: 0)
            }

            Text(paused ? "Paused — tap Resume to continue." : engine.coaching)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(paused ? MV.inkMuted : scopeGreen)
                .fixedSize(horizontal: false, vertical: true)

            // Wellness-toned range note — informational wording only (not a medical
            // alert): typical adult resting range is 60–100 bpm.
            if let bpmValue = liveBpm, bpmValue > 100 {
                Label("Above the typical resting range (60–100 BPM). Sit still, relax, and re-measure. Wellness info only — not medical advice.",
                      systemImage: "info.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MV.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            pulseShapeCard
            hrvCard(metrics: live)
            estimateGrid(metrics: live)

            HStack(spacing: MV.s12) {
                controlButton(engine.torchOn ? "bolt.fill" : "bolt.slash.fill", "Flash",
                              tint: engine.torchOn ? MV.warn : MV.inkMuted) { engine.toggleTorch() }
                    .disabled(paused).opacity(paused ? 0.4 : 1)
                controlButton("arrow.clockwise", "Recalibrate", tint: MV.accent) {
                    Haptics.commit(); engine.recalibrate()
                }
                    .disabled(paused).opacity(paused ? 0.4 : 1)
                controlButton(paused ? "play.fill" : "stop.fill", paused ? "Resume" : "Stop",
                              tint: paused ? MV.good : MV.bad) { togglePause() }
            }

            Text("For wellness & fitness only — not a medical device.")
                .font(.caption2).foregroundStyle(MV.inkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Pulse the heart at the measured rate (mirrors the Home hero), restarting when
    /// the BPM bucket changes via `.task(id: bpmBucket)`.
    private func bpmBucket(_ bpm: Double?) -> Int { Int((bpm ?? 75) / 5) }

    /// (Re)start the beat pulse at the current rate. A `repeatForever` animation
    /// only picks up a new rate when the property changes again, so the flag is
    /// snapped back first and re-armed a beat later.
    private func restartBeat() async {
        guard !reduceMotion else { return }
        beat = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        let bpm = model.liveMetrics?.hrBpm ?? engine.bpm ?? 75
        let interval = 60.0 / Swift.max(40, Swift.min(200, bpm))
        withAnimation(.easeInOut(duration: interval * 0.5).repeatForever(autoreverses: true)) {
            beat = true
        }
    }

    /// Compact HRV — stress & recovery card (wellness). Shows "—" until enough clean
    /// beats on a good signal, so it never displays a garbage value.
    private func hrvCard(metrics: MetricsSnapshot?) -> some View {
        let rmssd = metrics?.rmssdMs ?? engine.hrvRmssd
        let sdnn = metrics?.sdnnMs
        let band = Self.stressBand(for: rmssd)
        let hasContact = metrics?.contact ?? (engine.uiState == .measuring)
        return HStack(spacing: MV.s12) {
            Image(systemName: "heart.text.square").font(.system(size: 22))
                .foregroundStyle(Self.stressColor(band))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("HRV — stress & recovery").font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                    Spacer()
                    Text(band?.label ?? (hasContact ? "Collecting" : "—"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.stressColor(band))
                }
                Text(hrvSummary(rmssd: rmssd, sdnn: sdnn, hasContact: hasContact))
                    .font(.caption2).foregroundStyle(MV.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MV.s12)
        .background(RoundedRectangle(cornerRadius: MV.rControl, style: .continuous).fill(MV.surface))
    }

    /// Cardiographer-style averaged beat view. It is a visual pulse-shape aid, not
    /// a diagnosis; the notch marker is intentionally labelled as an area.
    private var pulseShapeCard: some View {
        VStack(alignment: .leading, spacing: MV.s8) {
            HStack {
                Label("Averaged pulse", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MV.ink)
                Spacer()
                Text(engine.qualityBand.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.qualityColor(engine.qualityBand))
            }
            AveragedPulseShape(samples: engine.displaySamples,
                               lineColor: scopeGreen,
                               notchColor: MV.warn)
                .frame(height: 92)
            Text("Shape view is for wellness context only. Hold a steady signal for a cleaner average.")
                .font(.caption2)
                .foregroundStyle(MV.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MV.s12)
        .background(RoundedRectangle(cornerRadius: MV.rControl, style: .continuous).fill(MV.surface))
    }

    private func estimateGrid(metrics m: MetricsSnapshot?) -> some View {
        let hasContact = m?.contact ?? false
        let hrvBand = Self.stressBand(for: m?.rmssdMs)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MV.s8) {
            detailTile("Breathing", Fmt.bpm(m?.respRateBpm), "br/min", "wind", MV.navy,
                       note: secondaryNote(value: m?.respRateBpm, hasContact: hasContact))
            detailTile("RMSSD", Fmt.ms(m?.rmssdMs), "ms", "heart.text.square", Self.stressColor(hrvBand),
                       note: secondaryNote(value: m?.rmssdMs, hasContact: hasContact))
            detailTile("SDNN", Fmt.ms(m?.sdnnMs), "ms", "waveform.path", MV.bioz,
                       note: secondaryNote(value: m?.sdnnMs, hasContact: hasContact))
            detailTile("Signal", Fmt.int(m?.signalQuality), "/100", "hand.point.up.left.fill",
                       Self.qualityColor(m?.signalQuality, fallback: engine.qualityBand),
                       note: hasContact ? "Live" : placePrompt)
        }
    }

    private func detailTile(_ title: String, _ value: String, _ unit: String,
                            _ icon: String, _ tint: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MV.inkMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(MV.number(22))
                    .foregroundStyle(MV.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MV.inkMuted)
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(MV.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: MV.rControl, style: .continuous).fill(MV.surface))
    }

    private func secondaryNote(value: Double?, hasContact: Bool) -> String {
        if value != nil { return "Live estimate" }
        return hasContact ? "Collecting" : placePrompt
    }

    private func hrvSummary(rmssd: Double?, sdnn: Double?, hasContact: Bool) -> String {
        guard let rmssd else {
            if hasContact { return "Collecting clean beats for HRV." }
            return model.scanMode == .palm
                ? "Show your palm and hold steady."
                : "Place finger and hold steady."
        }
        if let sdnn {
            return "\(Int(rmssd.rounded())) ms RMSSD · \(Int(sdnn.rounded())) ms SDNN · wellness estimate"
        }
        return "\(Int(rmssd.rounded())) ms RMSSD · wellness estimate"
    }

    /// Colour the HRV stress/recovery readout by band (green calm → red tense),
    /// not always green — a "Tense" reading must not read as good.
    private static func stressColor(_ band: PPGStressBand?) -> Color {
        switch band {
        case .calm: return MV.good
        case .balanced: return MV.warn
        case .tense: return MV.bad
        case nil: return MV.inkMuted
        }
    }

    private static func stressBand(for rmssd: Double?) -> PPGStressBand? {
        guard let rmssd, rmssd.isFinite else { return nil }
        if rmssd >= 50 { return .calm }
        if rmssd >= 25 { return .balanced }
        return .tense
    }

    private static func qualityColor(_ quality: Int?, fallback: PPGQualityBand) -> Color {
        guard let quality else { return qualityColor(fallback) }
        if quality >= 64 { return MV.good }
        if quality >= 54 { return MV.warn }
        return MV.bad
    }

    private static func qualityColor(_ band: PPGQualityBand) -> Color {
        switch band {
        case .good: return MV.good
        case .fair: return MV.warn
        case .poor: return MV.bad
        }
    }

    private func togglePause() {
        Haptics.commit()
        if paused { model.startMeasuring(); paused = false }
        else { model.stopMeasuring(); paused = true }
    }

    private func controlButton(_ icon: String, _ label: String, tint: Color,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(label).font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MV.s12)
            .background(RoundedRectangle(cornerRadius: MV.rControl, style: .continuous).fill(MV.surface))
        }
        .buttonStyle(.plain)
    }
}

private struct AveragedPulseShape: View {
    let samples: [PPGSample]
    let lineColor: Color
    let notchColor: Color

    private let pointsPerBeat = 80

    var body: some View {
        Canvas { ctx, size in
            let shape = averageShape()
            drawGrid(ctx, size)
            guard shape.count > 2 else {
                ctx.draw(Text("Hold steady for pulse shape").font(.caption),
                         at: CGPoint(x: size.width / 2, y: size.height / 2),
                         anchor: .center)
                return
            }

            var path = Path()
            path.move(to: point(0, shape[0], shape, size))
            for i in 1..<shape.count {
                path.addLine(to: point(i, shape[i], shape, size))
            }
            ctx.stroke(path, with: .color(lineColor),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

            let notchIndex = notchCandidate(in: shape)
            let notchPoint = point(notchIndex, shape[notchIndex], shape, size)
            var marker = Path()
            marker.move(to: CGPoint(x: notchPoint.x, y: 6))
            marker.addLine(to: CGPoint(x: notchPoint.x, y: size.height - 18))
            ctx.stroke(marker, with: .color(notchColor.opacity(0.75)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ctx.fill(Path(ellipseIn: CGRect(x: notchPoint.x - 3, y: notchPoint.y - 3, width: 6, height: 6)),
                     with: .color(notchColor))
            ctx.draw(Text("notch area").font(.caption2),
                     at: CGPoint(x: min(size.width - 38, notchPoint.x + 34), y: 12),
                     anchor: .center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Averaged pulse shape")
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        for r in 1..<3 {
            let y = size.height * CGFloat(r) / 3
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(MV.separator.opacity(0.7)), lineWidth: 0.5)
        }
    }

    private func point(_ index: Int, _ value: Double, _ shape: [Double], _ size: CGSize) -> CGPoint {
        let lo = shape.min() ?? -1
        let hi = shape.max() ?? 1
        let span = max(1e-6, hi - lo)
        let x = Double(index) / Double(max(1, shape.count - 1)) * size.width
        let y = size.height - ((value - lo) / span * (size.height - 18)) - 9
        return CGPoint(x: x, y: y)
    }

    private func averageShape() -> [Double] {
        let real = samples.filter { !$0.isReconstructed }
        guard real.count >= 40 else { return [] }
        let vals = real.map(\.value)
        let peaks = peakIndexes(vals)
        guard peaks.count >= 4 else { return [] }

        var beats: [[Double]] = []
        for pair in zip(peaks.dropLast(), peaks.dropFirst()) {
            let start = pair.0
            let end = pair.1
            guard end - start >= 8, end <= vals.count else { continue }
            beats.append(Self.resample(Array(vals[start..<end]), to: pointsPerBeat))
        }
        guard !beats.isEmpty else { return [] }

        var avg = [Double](repeating: 0, count: pointsPerBeat)
        for beat in beats.suffix(8) {
            let lo = beat.min() ?? 0
            let hi = beat.max() ?? 1
            let span = max(1e-6, hi - lo)
            for i in 0..<pointsPerBeat {
                avg[i] += (beat[i] - lo) / span
            }
        }
        return avg.map { $0 / Double(min(8, beats.count)) }
    }

    private func peakIndexes(_ values: [Double]) -> [Int] {
        guard values.count > 5 else { return [] }
        var out: [Int] = []
        let minGap = 9
        for i in 2..<(values.count - 2) {
            guard values[i] > values[i - 1],
                  values[i] > values[i + 1],
                  values[i] >= values[i - 2],
                  values[i] >= values[i + 2] else { continue }
            if let last = out.last, i - last < minGap {
                if values[i] > values[last] { out[out.count - 1] = i }
            } else {
                out.append(i)
            }
        }
        return out
    }

    private func notchCandidate(in shape: [Double]) -> Int {
        guard shape.count > 20 else { return max(0, shape.count / 2) }
        let start = shape.count / 2
        let end = min(shape.count - 2, Int(Double(shape.count) * 0.82))
        guard start < end else { return shape.count * 2 / 3 }
        return (start...end).min(by: { shape[$0] < shape[$1] }) ?? shape.count * 2 / 3
    }

    private static func resample(_ xs: [Double], to n: Int) -> [Double] {
        guard xs.count > 1, n > 1 else { return [Double](repeating: xs.first ?? 0, count: n) }
        var out = [Double](repeating: 0, count: n)
        let scale = Double(xs.count - 1) / Double(n - 1)
        for i in 0..<n {
            let x = Double(i) * scale
            let i0 = Int(x)
            let i1 = min(i0 + 1, xs.count - 1)
            let f = x - Double(i0)
            out[i] = xs[i0] * (1 - f) + xs[i1] * f
        }
        return out
    }
}
