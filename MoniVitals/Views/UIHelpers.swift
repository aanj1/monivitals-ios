//
//  UIHelpers.swift
//  MoniVitals
//
//  Shared formatting helpers and small reusable views (metric tiles, status pills).
//  Deliberately avoids any diagnostic/clinical language — values are labeled as
//  friendly estimates measured on your phone.
//

import SwiftUI

// MARK: - Formatting

enum Fmt {
    /// The placeholder shown when a value is not yet available.
    static let none = "—"

    static func opt(_ v: Double?, decimals: Int = 0, suffix: String = "") -> String {
        // Guard against nil AND non-finite values (NaN/±inf) which would otherwise
        // format as "nan"/"inf" and leak into tiles.
        guard let v, v.isFinite else { return none }
        return String(format: "%.\(decimals)f", v) + suffix
    }

    static func bpm(_ v: Double?) -> String { opt(v, decimals: 0) }
    static func ms(_ v: Double?) -> String { opt(v, decimals: 0) }

    /// Format an optional integer-valued metric (quality/movement), returning the
    /// placeholder while the value is absent rather than a misleading "0".
    static func int(_ v: Int?) -> String {
        guard let v else { return none }
        return "\(v)"
    }

    static func duration(_ ms: Double) -> String {
        let totalSec = Int(ms / 1000)
        return String(format: "%02d:%02d", totalSec / 60, totalSec % 60)
    }
}

// MARK: - Metric tile

struct MetricTile<Gauge: View>: View {
    let title: String
    let value: String
    let unit: String
    let note: String?
    let systemImage: String?
    let tint: Color
    /// When true and the value is still the placeholder, show a subtle skeleton bar
    /// with a "warming up…" note instead of a bare "—".
    let warmsUp: Bool
    /// Optional short history for a tiny decorative trend line at the tile's foot.
    let trend: [Double]
    /// A slim "where this sits" range gauge shown beneath the value.
    @ViewBuilder let gauge: () -> Gauge

    init(title: String,
         value: String,
         unit: String = "",
         note: String? = nil,
         systemImage: String? = nil,
         tint: Color = MV.accent,
         warmsUp: Bool = false,
         trend: [Double] = [],
         @ViewBuilder gauge: @escaping () -> Gauge) {
        self.title = title
        self.value = value
        self.unit = unit
        self.note = note
        self.systemImage = systemImage
        self.tint = tint
        self.warmsUp = warmsUp
        self.trend = trend
        self.gauge = gauge
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // (see convenience no-gauge init below the type)
    /// Bumped briefly whenever the value changes, to emphasise the update.
    @State private var pop = false

    /// True while this tile is awaiting its first real value.
    private var isWarming: Bool { warmsUp && value == Fmt.none }

    var body: some View {
        VStack(alignment: .leading, spacing: MV.s8) {
            HStack(spacing: MV.s8) {
                if let systemImage { IconBadge(systemName: systemImage, tint: tint, size: 26) }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MV.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if isWarming {
                SkeletonBar()
                    .frame(width: 46, height: 24)
                    .padding(.vertical, 1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(MV.number(24))
                        .foregroundStyle(MV.ink)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .scaleEffect(pop && !reduceMotion ? 1.06 : 1, anchor: .leading)
                    if !unit.isEmpty {
                        Text(unit).font(.caption.weight(.medium)).foregroundStyle(MV.inkMuted)
                    }
                }
            }
            if let note = displayNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(MV.inkMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if trend.count > 1 && !isWarming {
                Sparkline(values: trend, color: tint.opacity(0.75), lineWidth: 1.3)
                    .frame(height: 12)
            }
            // Slim "where this sits" gauge, always shown (dimmed when no value yet).
            gauge()
                .padding(.top, MV.s4)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .mvCard(padding: MV.s12, radius: MV.rTile)
        .animation(.easeInOut(duration: 0.25), value: value)
        .onChange(of: value) { _ in
            guard !isWarming else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.2)) { pop = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var displayNote: String? {
        isWarming ? "warming up…" : note
    }

    /// One combined VoiceOver phrase, e.g. "Heart rate, 92 bpm, recorded ~92".
    private var accessibilityText: String {
        if isWarming { return "\(title), warming up" }
        var parts = [title]
        if value == Fmt.none {
            parts.append("no reading yet")
        } else {
            parts.append(unit.isEmpty ? value : "\(value) \(unit)")
        }
        if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

extension MetricTile where Gauge == EmptyView {
    /// Convenience init for a tile with no range gauge.
    init(title: String,
         value: String,
         unit: String = "",
         note: String? = nil,
         systemImage: String? = nil,
         tint: Color = MV.accent,
         warmsUp: Bool = false,
         trend: [Double] = []) {
        self.init(title: title, value: value, unit: unit, note: note,
                  systemImage: systemImage, tint: tint, warmsUp: warmsUp,
                  trend: trend, gauge: { EmptyView() })
    }
}

/// A soft shimmering placeholder used while a value warms up. Respects Reduce Motion
/// (renders a static bar rather than a moving shimmer).
private struct SkeletonBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(MV.surfaceAlt)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, MV.inkMuted.opacity(0.10), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .offset(x: reduceMotion ? 0 : (shimmer ? 60 : -60))
                    .opacity(reduceMotion ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Connection pill

struct ConnectionPill: View {
    let state: ConnectionState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isLive: Bool { state == .measuring }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if isLive && !reduceMotion {
                    Circle().fill(color.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulse ? 2.2 : 1)
                        .opacity(pulse ? 0 : 0.6)
                }
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(MV.ink)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(MV.surface))
        .overlay(Capsule().stroke(MV.separator, lineWidth: 1))
        .onAppear {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .onChange(of: state) { _ in
            pulse = false
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal status")
        .accessibilityValue(label)
    }

    private var label: String {
        switch state {
        case .measuring: return "Live"
        case .starting: return "Starting…"
        case .disconnected, .unsupported: return "Paused"
        }
    }

    private var color: Color {
        switch state {
        case .measuring: return MV.good
        case .starting: return MV.warn
        case .disconnected, .unsupported: return MV.inkMuted
        }
    }
}

// MARK: - Share sheet (UIActivityViewController) for exporting a bundle folder

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
