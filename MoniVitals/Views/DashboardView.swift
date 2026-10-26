//
//  DashboardView.swift
//  MoniVitals
//
//  Home screen: a hero Heart-rate card plus tiles for Respiratory rate, HRV, and
//  Signal quality / Movement, with one live pulse waveform. Values are friendly
//  estimates worked out on your phone — no clinical language.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPairing = false

    private let columns = [
        GridItem(.flexible(), spacing: MV.s12),
        GridItem(.flexible(), spacing: MV.s12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MV.s16) {
                    SourcePicker(source: model.sourceKind,
                                 onSelect: { model.selectSource($0) },
                                 onPickDevice: { showPairing = true })

                    if model.connectionState == .unsupported {
                        unavailableCard
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    VStack(alignment: .leading, spacing: MV.s12) {
                        SectionHeader(title: "Your readings",
                                      subtitle: model.sourceKind == .device
                                        ? "Live from your MoniVitals device"
                                        : "Estimated live from your fingertip")
                        lastRecordedLine
                        heroCard
                        metricTiles
                    }

                    VStack(alignment: .leading, spacing: MV.s12) {
                        SectionHeader(title: "Live pulse")
                        if model.buffers.ppgGreen.length > 1 {
                            WaveformStrip(title: "Pulse", buffer: model.buffers.ppgGreen,
                                          windowSec: 6, color: MV.ppg, height: 120)
                        } else {
                            Text("Start Measure to stream a live pulse here.")
                                .font(.caption).foregroundStyle(MV.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, MV.s12)
                        }
                    }

                    footnote
                }
                .padding(.horizontal, MV.s16)
                .padding(.top, MV.s8)
                .padding(.bottom, MV.s16)
            }
            .background(MV.bg)
            .navigationTitle("MoniVitals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("MoniVitals").font(.headline).foregroundStyle(MV.navy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionPill(state: model.connectionState)
                }
            }
            .sheet(isPresented: $showPairing) { DevicePairingView() }
        }
    }

    private var unavailableCard: some View {
        let isDevice = model.sourceKind == .device
        return HStack(alignment: .top, spacing: MV.s12) {
            IconBadge(systemName: isDevice ? "wave.3.right" : "camera.fill", tint: MV.warn, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(isDevice ? "Connect your MoniVitals device"
                              : "Measuring needs a real iPhone camera")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                Text(model.stateMessage ??
                     (isDevice
                      ? "Power on the sensor, then tap MoniVitals device to pair over Bluetooth."
                      : "Open MoniVitals on your iPhone to measure your heart rate from your fingertip."))
                    .font(.caption).foregroundStyle(MV.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isDevice {
                Button("Pair") { showPairing = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MV.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard(padding: MV.s12)
    }

    // MARK: - Tiles

    private var metricTiles: some View {
        let m = displayMetrics
        let warming = model.connectionState == .measuring
        return LazyVGrid(columns: columns, spacing: MV.s12) {
            // SpO₂ appears only for the MoniVitals device (the camera can't estimate it).
            if model.showsSpo2 {
                MetricTile(title: "Blood oxygen", value: Fmt.opt(m?.spo2Pct, decimals: 0), unit: "%",
                           systemImage: "drop.fill", tint: MV.magenta, warmsUp: warming) {
                    MetricGauges.spo2(m?.spo2Pct)
                }
            }
            MetricTile(title: "Respiratory rate", value: Fmt.bpm(m?.respRateBpm), unit: "br/min",
                       systemImage: "wind", tint: MV.navy, warmsUp: warming) {
                MetricGauges.respiratoryRate(m?.respRateBpm)
            }
            MetricTile(title: "HRV (RMSSD)", value: Fmt.ms(m?.rmssdMs), unit: "ms",
                       note: "HRV is personal — trends matter more than one number.",
                       systemImage: "waveform.path", tint: MV.bioz, warmsUp: warming) {
                MetricGauges.hrv(m?.rmssdMs)
            }
            MetricTile(title: "Signal quality", value: Fmt.int(m?.signalQuality), unit: "/100",
                       systemImage: "hand.point.up.left.fill", tint: MV.good, warmsUp: warming) {
                MetricGauges.signalQuality((m?.signalQuality).map(Double.init))
            }
            // Movement is the phone's own stillness — only meaningful for the
            // fingertip camera, not a paired finger sensor.
            if model.sourceKind == .camera {
                MetricTile(title: "Movement", value: Fmt.int(m?.motion), unit: "/100",
                           systemImage: "figure.walk", tint: MV.pink, warmsUp: warming) {
                    MetricGauges.movement((m?.motion).map(Double.init))
                }
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.caption2).foregroundStyle(MV.accent)
            Text("For curiosity and wellbeing — not a substitute for medical care.")
                .font(.caption2).foregroundStyle(MV.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, MV.s4)
    }

    // MARK: - Heart-rate hero card

    private var heroCard: some View {
        HeartRateHeroCard(bpm: displayMetrics?.hrBpm,
                          trend: model.hrTrend,
                          measuring: model.connectionState == .measuring,
                          contact: displayMetrics?.contact ?? false,
                          source: model.sourceKind)
    }

    private var displayMetrics: MetricsSnapshot? {
        if let live = model.liveMetrics { return live }
        guard let last = model.lastVitals else { return nil }
        return MetricsSnapshot(
            tUs: 0,
            hrBpm: last.hrBpm,
            respRateBpm: last.respRateBpm,
            rmssdMs: last.rmssdMs,
            sdnnMs: last.sdnnMs,
            signalQuality: last.signalQuality,
            motion: last.motion,
            contact: true,
            spo2Pct: last.spo2Pct
        )
    }

    @ViewBuilder
    private var lastRecordedLine: some View {
        if let last = model.lastVitals {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(MV.accent)
                Text("Last recorded \(ReviewView.displayDate(last.capturedAt))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MV.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Home's hero vital: full-width Heart-rate card with a large numeral, a live
/// mini-sparkline of the recent HR trend, and a gentle beat pulse on the icon.
private struct HeartRateHeroCard: View {
    let bpm: Double?
    let trend: [Double]
    let measuring: Bool
    let contact: Bool
    let source: MeasurementSource

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = false

    private var isWarming: Bool { measuring && bpm == nil }
    private var bpmBucket: Int { Int((bpm ?? 0) / 5) }

    private var subtitleText: String {
        if !measuring { return "Open the Measure tab to begin." }
        if bpm == nil {
            return contact ? "Hold still — settling…"
                           : (source == .device
                              ? "Rest a fingertip on the MoniVitals device."
                              : "Rest a fingertip over the rear camera.")
        }
        return "Live estimate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MV.s12) {
            HStack(spacing: MV.s8) {
                IconBadge(systemName: "heart.fill", tint: MV.magenta, size: 30)
                    .scaleEffect(beat && !reduceMotion ? 1.12 : 1.0)
                    .task(id: bpmBucket) { await restartBeat() }
                Text("Heart rate")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MV.ink)
                Spacer()
                Text("On-device")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MV.navy)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(MV.navy.opacity(0.18)))
            }

            HStack(alignment: .center, spacing: MV.s16) {
                VStack(alignment: .leading, spacing: 2) {
                    if isWarming {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(MV.surfaceAlt)
                            .frame(width: 88, height: 40)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Fmt.bpm(bpm))
                                .font(MV.number(34))
                                .foregroundStyle(MV.ink)
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text("bpm")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(MV.inkMuted)
                        }
                    }
                    Text(subtitleText)
                        .font(.caption2)
                        .foregroundStyle(MV.inkMuted)
                }
                Spacer(minLength: MV.s8)
                if trend.count > 1 {
                    Sparkline(values: trend, color: MV.magenta, lineWidth: 1.8, fills: true)
                        .frame(maxWidth: 150)
                        .frame(height: 44)
                }
            }

            // Prominent HR range gauge — where this heart rate sits.
            MetricGauges.heartRate(bpm)
                .padding(.top, MV.s4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(bpm == nil ? "not available yet. \(subtitleText)" : "\(Fmt.bpm(bpm)) bpm")
    }

    /// (Re)start the beat pulse at the current rate. A `repeatForever` animation
    /// only picks up a new rate when the property changes again, so the flag is
    /// snapped back first and re-armed a beat later.
    private func restartBeat() async {
        guard !reduceMotion else { return }
        beat = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        let interval = bpm.map { 60.0 / max(40, min(200, $0)) } ?? 1.0
        withAnimation(.easeInOut(duration: interval * 0.5).repeatForever(autoreverses: true)) {
            beat = true
        }
    }
}
