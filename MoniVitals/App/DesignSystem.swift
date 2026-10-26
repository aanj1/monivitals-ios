//
//  DesignSystem.swift
//  MoniVitals
//
//  Small shared UI building blocks so every screen shares one visual language:
//  tinted icon badges, section headers, chips, and button styles. Built on the MV
//  palette + spacing tokens in Theme.swift.
//

import SwiftUI

/// A tinted, rounded icon chip used in tiles and rows.
struct IconBadge: View {
    let systemName: String
    var tint: Color = MV.accent
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }
}

/// A consistent section heading with an optional supporting line.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(MV.navy)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(MV.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small pill chip (used for a waveform's colored label, tags, etc.).
struct ChipLabel: View {
    let text: String
    var color: Color = MV.navy

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(MV.ink)
        }
    }
}

/// Full-width prominent action button. `fill` defaults to the brand accent but can
/// be swapped (e.g. `MV.bad` for a prominent stop action).
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = MV.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: MV.rControl, style: .continuous)
                    .fill(fill)
            )
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary (tinted, low-emphasis) action button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: MV.rControl, style: .continuous)
                    .fill(MV.accent.opacity(0.12))
            )
            .foregroundStyle(MV.accent)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A tiny static trend line drawn from a short rolling array of metric values.
/// Purely decorative — always paired with a numeric readout, so it is hidden
/// from accessibility.
struct Sparkline: View {
    let values: [Double]
    var color: Color = MV.accent
    var lineWidth: CGFloat = 1.5
    /// Soft gradient fill under the line (used by the hero card; tiles stay line-only).
    var fills: Bool = false

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            var lo = values.min()!, hi = values.max()!
            if !(hi > lo) { hi = lo + 1 }
            let margin = (hi - lo) * 0.18
            lo -= margin; hi += margin

            let w = Double(size.width), h = Double(size.height)
            let n = Double(values.count)
            func x(_ i: Int) -> Double { Double(i) / (n - 1) * w }
            func y(_ v: Double) -> Double { h - (v - lo) / (hi - lo) * h }

            var path = Path()
            path.move(to: CGPoint(x: x(0), y: y(values[0])))
            for i in 1..<values.count {
                path.addLine(to: CGPoint(x: x(i), y: y(values[i])))
            }

            if fills {
                var area = path
                area.addLine(to: CGPoint(x: w, y: h))
                area.addLine(to: CGPoint(x: 0, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.18), color.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            }

            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Leading-edge dot, matching the live waveform strips.
            if let last = values.last {
                let p = CGPoint(x: x(values.count - 1), y: y(last))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                         with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A round progress gauge (0…1) with a soft track — used for "Clean segments %".
struct RingGauge: View {
    /// Fraction 0…1.
    let value: Double
    var tint: Color = MV.good
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(MV.surfaceAlt, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: value)
        }
        .accessibilityHidden(true)
    }
}

/// Segmented picker for the measurement source (Fingertip camera vs MoniVitals
/// device). Selecting "MoniVitals device" opens pairing via `onPickDevice`.
struct SourcePicker: View {
    let source: MeasurementSource
    let onSelect: (MeasurementSource) -> Void
    /// Called when the user picks (or re-taps) the device source, so the caller can
    /// present the pairing sheet.
    var onPickDevice: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: MV.s8) {
            Text("Measure with")
                .font(.caption.weight(.medium))
                .foregroundStyle(MV.inkMuted)
            HStack(spacing: MV.s8) {
                ForEach(MeasurementSource.allCases, id: \.self) { kind in
                    let selected = kind == source
                    Button {
                        let changed = kind != source
                        if changed { onSelect(kind) }
                        if kind == .device { onPickDevice() }
                        // Haptic only on a real action (source change or opening
                        // pairing) — not on re-tapping the already-selected camera.
                        if changed || kind == .device { Haptics.commit() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: kind.systemImage)
                                .font(.caption.weight(.semibold))
                            Text(kind.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selected ? .white : MV.ink)
                        .background(
                            RoundedRectangle(cornerRadius: MV.rControl, style: .continuous)
                                .fill(selected ? MV.accent : MV.surfaceAlt))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }
}

// MARK: - Range gauge (where a reading sits)

/// One contiguous zone of a `RangeGauge`, running from the previous zone's `upTo`
/// value up to this one's `upTo`. `color` tints the track segment + the chip when
/// the value lands here; `label` is the one-word wellness word ("Typical", "High").
struct GaugeZone: Equatable {
    /// Upper bound of this zone (inclusive-ish; the last zone should reach the span's
    /// max). Segments are `[previousUpTo … upTo]`.
    let upTo: Double
    let color: Color
    let label: String

    init(upTo: Double, color: Color, label: String) {
        self.upTo = upTo
        self.color = color
        self.label = label
    }
}

/// Result of placing a value on a gauge: the fraction (0…1) along the span for the
/// marker, and the index of the zone the value falls into. Pure + testable.
struct GaugePlacement: Equatable {
    /// 0…1 position of the marker along the span (clamped).
    let fraction: Double
    /// Index into the `zones` array of the zone the value sits in.
    let zoneIndex: Int
}

/// Pure helper: given a value, a span, and ordered zones, return the marker
/// fraction (clamped 0…1) and the selected zone index. No SwiftUI, so it is unit
/// testable. Zones are matched by their `upTo` bound in order; a value above every
/// bound falls into the last zone.
///
/// - Precondition: `span.lowerBound < span.upperBound` and `zones` is non-empty.
func gaugePlacement(value: Double, span: ClosedRange<Double>, zones: [GaugeZone]) -> GaugePlacement {
    // Marker fraction along the span, clamped to the ends.
    let width = span.upperBound - span.lowerBound
    let raw = width > 0 ? (value - span.lowerBound) / width : 0
    let fraction = min(1, max(0, raw))

    // Zone selection: first zone whose upper bound the value does not exceed.
    var index = zones.count - 1
    for (i, zone) in zones.enumerated() where value < zone.upTo {
        index = i
        break
    }
    return GaugePlacement(fraction: fraction, zoneIndex: max(0, index))
}

/// A slim horizontal "where this sits" gauge: a rounded track segmented by zone
/// colors (green/amber/red), an animated marker at the value's position, tiny
/// min/max end labels, and a one-word zone chip tinted to the current zone.
///
/// Wellness framing only — zones read "Low / Typical / High", never
/// "normal/abnormal". When `value == nil` the track is dimmed with no marker.
struct RangeGauge: View {
    let value: Double?
    let span: ClosedRange<Double>
    let zones: [GaugeZone]
    var unit: String = ""
    /// Human name of the metric, used only for the VoiceOver label.
    var metricName: String = ""
    /// Height of the track (marker matches).
    var trackHeight: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var placement: GaugePlacement? {
        guard let value, value.isFinite, !zones.isEmpty else { return nil }
        return gaugePlacement(value: value, span: span, zones: zones)
    }

    private var currentZone: GaugeZone? {
        guard let placement, zones.indices.contains(placement.zoneIndex) else { return nil }
        return zones[placement.zoneIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MV.s4) {
            // One-word zone chip above the track, tinted to the current zone.
            if let zone = currentZone {
                zoneChip(zone)
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    trackSegments(width: w)
                    if let placement {
                        marker
                            .position(x: markerX(placement.fraction, width: w),
                                      y: trackHeight / 2)
                            .animation(reduceMotion ? nil
                                       : .spring(response: 0.5, dampingFraction: 0.7),
                                       value: placement.fraction)
                            .transition(.opacity)
                    }
                }
                .frame(height: trackHeight)
            }
            .frame(height: trackHeight)

            // Tiny min / max end labels.
            HStack {
                Text(endLabel(span.lowerBound))
                Spacer(minLength: 0)
                Text(endLabel(span.upperBound))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(MV.inkMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Pieces

    private func zoneChip(_ zone: GaugeZone) -> some View {
        // Near-white text on a tinted capsule — readable on the dark canvas while the
        // tint still conveys the zone (same-hue text on a faint same-hue fill was invisible).
        Text(zone.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MV.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(zone.color.opacity(0.30)))
    }

    private func trackSegments(width: CGFloat) -> some View {
        let full = span.upperBound - span.lowerBound
        let dimmed = placement == nil
        return HStack(spacing: 1.5) {
            ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                let lower = i == 0 ? span.lowerBound : zones[i - 1].upTo
                let upper = min(zone.upTo, span.upperBound)
                let frac = full > 0 ? max(0, (upper - lower) / full) : 0
                Capsule()
                    .fill(zone.color.opacity(dimmed ? 0.18 : 0.75))
                    .frame(width: max(0, width * CGFloat(frac)))
            }
        }
        .frame(height: trackHeight)
        .clipShape(Capsule())
    }

    private var marker: some View {
        Capsule()
            .fill(MV.ink)
            .frame(width: 3, height: trackHeight + 4)
            .overlay(Capsule().stroke(MV.bg, lineWidth: 1))
    }

    private func markerX(_ fraction: Double, width: CGFloat) -> CGFloat {
        // Inset a hair so the marker's body stays visible at the extremes.
        let inset: CGFloat = 2
        let usable = max(0, width - inset * 2)
        return inset + usable * CGFloat(fraction)
    }

    private func endLabel(_ v: Double) -> String {
        String(format: "%g", v)
    }

    private var accessibilityText: String {
        guard let value, let zone = currentZone else {
            return metricName.isEmpty ? "No reading yet" : "\(metricName), no reading yet"
        }
        let num = String(format: "%g", value)
        let unitPart = unit.isEmpty ? "" : " \(unit)"
        let name = metricName.isEmpty ? "" : "\(metricName) "
        return "\(name)\(num)\(unitPart) — \(zone.label.lowercased()) range"
    }
}

/// Per-metric range gauges. One shared source of truth for the wellness ranges
/// (resting guidance, NOT medical thresholds) so every screen reads the same.
/// Each factory builds a `RangeGauge` for the given value (nil → dimmed track).
enum MetricGauges {
    /// Heart rate (bpm), span 40…140.
    static func heartRate(_ value: Double?) -> RangeGauge {
        RangeGauge(value: value, span: 40...140, zones: [
            GaugeZone(upTo: 50, color: MV.warn, label: "Low"),
            GaugeZone(upTo: 90, color: MV.good, label: "Typical"),
            GaugeZone(upTo: 110, color: MV.warn, label: "Elevated"),
            GaugeZone(upTo: 140, color: MV.bad, label: "High"),
        ], unit: "bpm", metricName: "Heart rate")
    }

    /// Respiratory rate (breaths/min), span 6…30.
    static func respiratoryRate(_ value: Double?) -> RangeGauge {
        RangeGauge(value: value, span: 6...30, zones: [
            GaugeZone(upTo: 10, color: MV.warn, label: "Low"),
            GaugeZone(upTo: 20, color: MV.good, label: "Typical"),
            GaugeZone(upTo: 24, color: MV.warn, label: "Elevated"),
            GaugeZone(upTo: 30, color: MV.bad, label: "High"),
        ], unit: "br/min", metricName: "Respiratory rate")
    }

    /// HRV — RMSSD (ms), span 0…120. Higher generally reads as more recovered, so
    /// the colors run the other way (Lower = bad, Higher = good).
    static func hrv(_ value: Double?) -> RangeGauge {
        RangeGauge(value: value, span: 0...120, zones: [
            GaugeZone(upTo: 20, color: MV.bad, label: "Lower"),
            GaugeZone(upTo: 50, color: MV.warn, label: "Moderate"),
            GaugeZone(upTo: 120, color: MV.good, label: "Higher"),
        ], unit: "ms", metricName: "HRV")
    }

    /// SpO₂ (%), span 85…100. Device source only (the camera can't estimate it).
    static func spo2(_ value: Double?) -> RangeGauge {
        RangeGauge(value: value, span: 85...100, zones: [
            GaugeZone(upTo: 92, color: MV.bad, label: "Low"),
            GaugeZone(upTo: 95, color: MV.warn, label: "Borderline"),
            GaugeZone(upTo: 100, color: MV.good, label: "Typical"),
        ], unit: "%", metricName: "Blood oxygen")
    }

    /// Signal quality (0…100), a simple bad→warn→good gradient.
    static func signalQuality(_ value: Double?) -> RangeGauge {
        RangeGauge(value: value, span: 0...100, zones: [
            GaugeZone(upTo: 40, color: MV.bad, label: "Weak"),
            GaugeZone(upTo: 70, color: MV.warn, label: "Fair"),
            GaugeZone(upTo: 100, color: MV.good, label: "Strong"),
        ], unit: "/100", metricName: "Signal quality")
    }

    /// Movement (0…100), lower is steadier — so green sits at the low end.
    static func movement(_ value: Double?) -> RangeGauge {
        RangeGauge(value: value, span: 0...100, zones: [
            GaugeZone(upTo: 30, color: MV.good, label: "Still"),
            GaugeZone(upTo: 60, color: MV.warn, label: "Some"),
            GaugeZone(upTo: 100, color: MV.bad, label: "Lots"),
        ], unit: "/100", metricName: "Movement")
    }
}

/// A subtle press treatment for full-width tappable rows (marker rows, list-style
/// buttons) that use `.plain` today and give no touch feedback.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: MV.rControl, style: .continuous)
                    .fill(MV.accent.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
