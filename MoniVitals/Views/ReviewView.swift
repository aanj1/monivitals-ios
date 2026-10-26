//
//  ReviewView.swift
//  MoniVitals
//
//  List saved clips, plot their stored pulse with Swift Charts (static data,
//  so Charts is appropriate here), and share each as a CSV bundle via a share sheet.
//

import Charts
import SwiftUI

private struct HRPoint: Identifiable { let id: String; let date: Date; let bpm: Double }

private struct SessionAverages {
    var hrBpm: Double?
    var respRateBpm: Double?
    var rmssdMs: Double?
    var sdnnMs: Double?
    var signalQuality: Double?
    var motion: Double?
    var spo2Pct: Double?

    init(metrics: [MetricsRecord]) {
        hrBpm = Self.avg(metrics.compactMap(\.hrBpm))
        respRateBpm = Self.avg(metrics.compactMap(\.respRateBpm))
        rmssdMs = Self.avg(metrics.compactMap(\.rmssdMs))
        sdnnMs = Self.avg(metrics.compactMap(\.sdnnMs))
        signalQuality = Self.avg(metrics.map { Double($0.signalQuality) })
        motion = Self.avg(metrics.map { Double($0.motion) })
        spo2Pct = Self.avg(metrics.compactMap(\.spo2Pct))
    }

    private static func avg(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sessions: [Session] = []
    @State private var trend: [HRPoint] = []
    /// The clip a delete was requested for (drives the confirmation dialog).
    @State private var pendingDelete: Session?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MV.s20) {
                    if sessions.isEmpty {
                        emptyState
                    } else {
                        if trend.count >= 2 { trendsSection }
                        VStack(alignment: .leading, spacing: MV.s12) {
                            SectionHeader(title: "Saved clips",
                                          subtitle: "\(sessions.count) saved on this phone")
                            VStack(spacing: MV.s12) {
                                ForEach(sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                }
                .padding(MV.s16)
            }
            .background(MV.bg)
            .navigationTitle("Saved Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Saved Clips").font(.headline).foregroundStyle(MV.navy)
                }
            }
            .navigationDestination(for: String.self) { id in
                SessionDetailView(sessionId: id)
            }
            .onAppear(perform: reload)
            .refreshable { await reloadAsync() }
            .confirmationDialog("Delete this clip?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { session in
                Button("Delete clip", role: .destructive) {
                    Haptics.warning()
                    model.deleteSession(session.id)
                    pendingDelete = nil
                    reload()
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("This removes the clip and its samples from this phone.")
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        NavigationLink(value: session.id) {
            HStack(spacing: MV.s12) {
                IconBadge(systemName: "waveform.path.ecg", tint: MV.navy, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.subjectCode)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                        Text(session.label.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MV.navy)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(MV.navy.opacity(0.10)))
                    }
                    HStack(spacing: 6) {
                        Text(Self.displayDate(session.startedAt))
                            .font(.caption).foregroundStyle(MV.inkMuted)
                        if let dur = Self.displayDuration(session) {
                            Text("·").font(.caption).foregroundStyle(MV.inkMuted)
                            HStack(spacing: 3) {
                                Image(systemName: "clock").font(.caption2)
                                Text(dur).font(.caption.weight(.medium)).monospacedDigit()
                            }
                            .foregroundStyle(MV.inkMuted)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(MV.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .mvCard(padding: MV.s12)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // Card rows live in a ScrollView (not a List), so swipe-to-delete doesn't
        // exist here — long-press offers Delete, confirmed by a dialog.
        .contextMenu {
            Button(role: .destructive) {
                pendingDelete = session
            } label: {
                Label("Delete clip", systemImage: "trash")
            }
        }
    }

    // MARK: - Row formatting

    private static let isoParser: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Render the stored ISO-8601 start time as a friendly local date, falling back
    /// to the raw string if it doesn't parse.
    static func displayDate(_ iso: String) -> String {
        guard let d = isoParser.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// Clip duration (MM:SS) from the stored start/end stamps, when both exist.
    static func displayDuration(_ session: Session) -> String? {
        guard let endedAt = session.endedAt,
              let start = isoParser.date(from: session.startedAt),
              let end = isoParser.date(from: endedAt),
              end > start else { return nil }
        return Fmt.duration(end.timeIntervalSince(start) * 1000)
    }

    private var emptyState: some View {
        VStack(spacing: MV.s16) {
            ZStack {
                Circle().fill(MV.navy.opacity(0.08)).frame(width: 92, height: 92)
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(MV.navy)
            }
            VStack(spacing: MV.s4) {
                Text("No saved clips yet")
                    .font(.title3.weight(.semibold)).foregroundStyle(MV.ink)
                Text("Save a short clip of the live pulse on the Measure tab, then review its waveform and share it as a CSV bundle here.")
                    .font(.subheadline).foregroundStyle(MV.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MV.s32)
        .padding(.horizontal, MV.s8)
        .mvCard()
        .padding(.top, MV.s24)
    }

    private func reload() {
        Task { await reloadAsync() }
    }

    /// Load + decode the session JSON off the main thread, then publish on main.
    private func reloadAsync() async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([Session], [HRPoint]) in
            let sessions = Store.shared.listSessions()
            let trend = sessions.compactMap { s -> HRPoint? in
                guard let date = Self.isoParser.date(from: s.startedAt) else { return nil }
                let hrs = Store.shared.listMetrics(s.id).compactMap { $0.hrBpm }
                guard !hrs.isEmpty else { return nil }
                return HRPoint(id: s.id, date: date, bpm: hrs.reduce(0, +) / Double(hrs.count))
            }.sorted { $0.date < $1.date }
            return (sessions, trend)
        }.value
        sessions = loaded.0
        trend = loaded.1
    }

    /// Heart-rate-over-time trend across saved clips (wellness — trends over single reads).
    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: MV.s12) {
            SectionHeader(title: "Heart-rate trend",
                          subtitle: "Average bpm across your saved clips")
            Chart(trend) { p in
                LineMark(x: .value("Date", p.date), y: .value("bpm", p.bpm))
                    .foregroundStyle(MV.magenta)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", p.date), y: .value("bpm", p.bpm))
                    .foregroundStyle(MV.magenta)
                    .symbolSize(28)
            }
            .chartYScale(domain: trendDomain)
            .frame(height: 150)
            .padding(MV.s12)
            .mvCard(padding: MV.s8)
        }
    }

    private var trendDomain: ClosedRange<Double> {
        let ys = trend.map(\.bpm)
        guard let lo = ys.min(), let hi = ys.max() else { return 40...140 }
        return Swift.max(30, lo - 10)...Swift.min(220, hi + 10)
    }
}

// MARK: - Session detail

struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let sessionId: String

    @State private var streams = SessionStreams()
    @State private var session: Session?
    @State private var exportURL: URL?
    @State private var showShare = false
    /// Average vitals for this clip, computed from its stored metrics.
    @State private var averages = SessionAverages(metrics: [])
    /// True once the background decode finished, so the "samples live on the
    /// phone that recorded them" card can't flash while loading.
    @State private var loaded = false

    /// False for clips restored from a cloud backup — their samples stay on
    /// the phone that recorded them, so only the details are shown here.
    private var hasWaveforms: Bool {
        !streams.ppg.green.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MV.s20) {
                if let s = session {
                    metaCard(s)
                }

                if hasWaveforms {
                    VStack(alignment: .leading, spacing: MV.s12) {
                        SectionHeader(title: "Pulse", subtitle: "Waveform shape only — not a heart-rate value")
                        chart(title: "Pulse", color: MV.ppg,
                              total: streams.ppg.green.count,
                              values: streams.ppg.green.prefix(4000).map(Double.init))
                        averagesCard
                    }
                } else if loaded {
                    // Restored from a cloud backup: the clip's details are here,
                    // but its samples never leave the phone that recorded them.
                    VStack(alignment: .leading, spacing: MV.s12) {
                        SectionHeader(title: "Pulse")
                        HStack(spacing: MV.s12) {
                            IconBadge(systemName: "iphone", tint: MV.navy, size: 34)
                            Text("The pulse for this clip lives on the phone that recorded it.")
                                .font(.subheadline).foregroundStyle(MV.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mvCard()
                    }
                }
            }
            .padding(MV.s16)
        }
        .background(MV.bg)
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Clip").font(.headline).foregroundStyle(MV.navy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportURL = model.exportSession(sessionId)
                    showShare = exportURL != nil
                    if showShare { Haptics.tap() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share clip as CSV")
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ActivityView(items: [url])
            }
        }
        .task {
            // Decode the stored session JSON off the main thread — a long clip's
            // sample chunks are megabytes — then publish the results on main.
            let id = sessionId
            let data = await Task.detached(priority: .userInitiated) {
                () -> (Session?, SessionStreams, SessionAverages) in
                (Store.shared.getSession(id),
                 Store.shared.readSessionStreams(id),
                 SessionAverages(metrics: Store.shared.listMetrics(id)))
            }.value
            session = data.0
            streams = data.1
            averages = data.2
            loaded = true
        }
    }

    private func metaCard(_ s: Session) -> some View {
        HStack(alignment: .top, spacing: MV.s12) {
            IconBadge(systemName: "doc.text", tint: MV.navy, size: 34)
            VStack(alignment: .leading, spacing: MV.s4) {
                Text("\(s.subjectCode) · \(s.label.rawValue)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(MV.magenta)
                    Text("Avg heart rate: \(Fmt.bpm(averages.hrBpm)) bpm")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(MV.navy)
                }
                .padding(.vertical, 1)
                Text("Started \(s.startedAt)").font(.caption).foregroundStyle(MV.inkMuted)
                if let ended = s.endedAt {
                    Text("Ended \(ended)").font(.caption).foregroundStyle(MV.inkMuted)
                }
                if hasWaveforms {
                    Text("\(streams.ppg.green.count) pulse samples")
                        .font(.caption).foregroundStyle(MV.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    private var averagesCard: some View {
        VStack(alignment: .leading, spacing: MV.s12) {
            SectionHeader(title: "Session averages", subtitle: "Saved from this recording")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MV.s8) {
                avgTile("Heart rate", Fmt.bpm(averages.hrBpm), "bpm", "heart.fill", MV.magenta)
                avgTile("Breathing", Fmt.bpm(averages.respRateBpm), "br/min", "wind", MV.navy)
                avgTile("RMSSD", Fmt.ms(averages.rmssdMs), "ms", "waveform.path", MV.bioz)
                avgTile("SDNN", Fmt.ms(averages.sdnnMs), "ms", "waveform", MV.ppg)
                avgTile("Signal", Fmt.opt(averages.signalQuality, decimals: 0), "/100", "hand.point.up.left.fill", MV.good)
                avgTile("Movement", Fmt.opt(averages.motion, decimals: 0), "/100", "figure.walk", MV.pink)
                if averages.spo2Pct != nil {
                    avgTile("Blood oxygen", Fmt.opt(averages.spo2Pct, decimals: 0), "%", "drop.fill", MV.magenta)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    private func avgTile(_ title: String, _ value: String, _ unit: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: MV.s8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MV.inkMuted)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MV.ink)
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(MV.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(MV.s8)
        .background(RoundedRectangle(cornerRadius: MV.rTile, style: .continuous).fill(MV.surfaceAlt))
    }

    @ViewBuilder
    private func chart(title: String, color: Color, total: Int, values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: MV.s8) {
            ChipLabel(text: title, color: color)
            if values.count > 1 {
                Chart {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("i", i), y: .value("v", v))
                            .foregroundStyle(color)
                    }
                }
                .chartXAxis(.hidden)
                // Y axis carries no numeric labels: this is a relative pulse
                // waveform (arbitrary brightness units), NOT a heart-rate scale —
                // showing "100–150" here reads as bpm and misleads. Gridlines only.
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(MV.separator)
                    }
                }
                .chartYScale(domain: Self.robustDomain(values))
                .frame(height: 140)
            } else {
                Text("Nothing here just yet.").font(.caption).foregroundStyle(MV.inkMuted)
            }
            if values.count < total {
                Text("Showing first \(values.count) of \(total) samples.")
                    .font(.caption2).foregroundStyle(MV.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    /// A robust y-domain (2nd–98th percentile + margin) so a lone startup transient
    /// spike doesn't squash the real waveform to a flat line near the axis.
    private static func robustDomain(_ v: [Double]) -> ClosedRange<Double> {
        guard v.count > 1 else { return 0...1 }
        var lo: Double, hi: Double
        if v.count >= 20 {
            let s = v.sorted()
            lo = s[Int(Double(s.count - 1) * 0.02)]
            hi = s[Int(Double(s.count - 1) * 0.98)]
        } else {
            lo = v.min() ?? 0
            hi = v.max() ?? 1
        }
        if !(hi > lo) { hi = lo + 1 }
        let margin = (hi - lo) * 0.08
        return (lo - margin)...(hi + margin)
    }
}
