//
//  MeasureView.swift
//  MoniVitals
//
//  The live measurement screen. Shows a big friendly guidance state ("rest a
//  fingertip over the rear camera, hold still"), a live pulse waveform, a gentle
//  settling spinner, a clear reading readout, and a Save button that keeps the
//  clip for a chosen profile. On a phone without a usable camera it shows the
//  warm "needs a real iPhone camera" state instead.
//

import SwiftUI
import UIKit

struct MeasureView: View {
    @EnvironmentObject private var model: AppModel

    @State private var label: SessionLabel = .rest
    @State private var notes = ""
    @State private var showSubjectSheet = false
    @State private var showPairing = false

    private var isDevice: Bool { model.sourceKind == .device }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MV.s20) {
                    SourcePicker(source: model.sourceKind,
                                 onSelect: { model.selectSource($0) },
                                 onPickDevice: { showPairing = true })

                    switch model.connectionState {
                    case .unsupported:
                        if isDevice { devicePairCard } else { unsupportedCard }
                    case .disconnected:
                        if isDevice { devicePairCard } else { startingCard }
                    case .starting:
                        startingCard
                    case .measuring:
                        if isDevice {
                            guidanceCard
                            pulseCard
                            readingCard
                            saveCard
                        } else {
                            // Camera: Cardiographer-style scope + gated BPM + controls.
                            CameraMeasureView(engine: model.ppg)
                            saveCard
                        }
                    }
                }
                .padding(MV.s16)
            }
            .background(MV.bg)
            .navigationTitle("Measure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Measure").font(.headline).foregroundStyle(MV.navy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionPill(state: model.connectionState)
                }
            }
            .sheet(isPresented: $showSubjectSheet) { SubjectPickerSheet() }
            .sheet(isPresented: $showPairing) { DevicePairingView() }
        }
        // Prepare the active source only when the user is on the Measure screen:
        // camera → open the camera (asks permission); device → resume its state.
        // Release it (camera + torch, or an idle scan) when they leave.
        .onAppear { model.connectCamera() }
        .onDisappear { model.leaveMeasure() }
    }

    /// Prompt to connect the MoniVitals device when the device source is chosen but
    /// nothing is connected yet.
    private var devicePairCard: some View {
        VStack(spacing: MV.s16) {
            ZStack {
                Circle().fill(MV.navy.opacity(0.10)).frame(width: 92, height: 92)
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(MV.navy)
            }
            VStack(spacing: MV.s4) {
                Text("Connect your MoniVitals device")
                    .font(.title3.weight(.semibold)).foregroundStyle(MV.ink)
                    .multilineTextAlignment(.center)
                Text(model.stateMessage ??
                     "Power on the sensor and pair over Bluetooth to start measuring.")
                    .font(.subheadline).foregroundStyle(MV.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Haptics.commit()
                showPairing = true
            } label: {
                Label("Pair a device", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MV.s24)
        .padding(.horizontal, MV.s8)
        .mvCard()
        .padding(.top, MV.s8)
    }

    // MARK: - States

    private var unsupportedCard: some View {
        VStack(spacing: MV.s16) {
            ZStack {
                Circle().fill(MV.warn.opacity(0.10)).frame(width: 92, height: 92)
                Image(systemName: "camera.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(MV.warn)
            }
            VStack(spacing: MV.s4) {
                Text("This needs a real iPhone camera")
                    .font(.title3.weight(.semibold)).foregroundStyle(MV.ink)
                    .multilineTextAlignment(.center)
                Text(model.stateMessage ??
                     "Open MoniVitals on your iPhone to measure your heart rate from your fingertip.")
                    .font(.subheadline).foregroundStyle(MV.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // If access was denied, give a one-tap route to iOS Settings (returning
            // to the app re-checks permission via resumeFromBackground).
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MV.s32)
        .padding(.horizontal, MV.s8)
        .mvCard()
        .padding(.top, MV.s24)
    }

    private var startingCard: some View {
        VStack(spacing: MV.s16) {
            ProgressView()
                .controlSize(.large)
                .tint(MV.accent)
            Text("Getting the camera ready…")
                .font(.subheadline).foregroundStyle(MV.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MV.s32)
        .padding(.horizontal, MV.s8)
        .mvCard()
        .padding(.top, MV.s24)
    }

    /// Guidance headline/subtitle. In camera mode it follows the calm 3-state PPG UI
    /// (Measuring / Adjust finger / Finger removed); in device mode it follows contact.
    private var guidanceCopy: (headline: String, subtitle: String, good: Bool) {
        let contact = model.liveMetrics?.contact ?? false
        let hasReading = model.liveMetrics?.hrBpm != nil
        if isDevice {
            if contact {
                return (hasReading ? "Looking good — keep holding" : "Hold still, settling…",
                        "Stay relaxed for a few seconds while the numbers steady.", true)
            }
            return ("Rest a fingertip on the sensor",
                    "Place your finger on the MoniVitals sensor, then hold still.", false)
        }
        switch model.cameraUIState {
        case .measuring:
            return (hasReading ? "Looking good — keep holding" : "Hold still, settling…",
                    "Stay relaxed for a few seconds while the numbers steady.", true)
        case .adjustFinger:
            return ("Adjust your finger",
                    "Move your fingertip so it covers the camera and torch, then hold still.", false)
        case .fingerRemoved:
            return ("Rest a fingertip over the rear camera",
                    "Cover the camera and torch gently, then hold still.", false)
        }
    }

    private var guidanceCard: some View {
        let g = guidanceCopy
        return VStack(alignment: .leading, spacing: MV.s12) {
            HStack(spacing: MV.s12) {
                IconBadge(systemName: g.good ? "hand.thumbsup.fill" : "hand.point.up.left.fill",
                          tint: g.good ? MV.good : MV.magenta, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.headline)
                        .font(.headline).foregroundStyle(MV.ink)
                    Text(g.subtitle)
                        .font(.caption).foregroundStyle(MV.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            let quality = model.liveMetrics?.signalQuality ?? model.contactQuality
            VStack(alignment: .leading, spacing: MV.s4) {
                HStack {
                    Text("Signal quality").font(.caption2).foregroundStyle(MV.inkMuted)
                    Spacer()
                    Text("\(quality)/100").font(.caption2.weight(.medium)).foregroundStyle(MV.ink)
                }
                MetricGauges.signalQuality(Double(quality))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    private var pulseCard: some View {
        VStack(alignment: .leading, spacing: MV.s8) {
            SectionHeader(title: "Live pulse")
            if isDevice {
                WaveformStrip(title: "Pulse", buffer: model.buffers.ppgGreen,
                              windowSec: 6, color: MV.ppg, height: 150)
            } else {
                // Camera: the calm display stream (stays continuous through brief dips).
                PPGPulseStrip(engine: model.ppg, height: 150)
            }
        }
    }

    private var readingCard: some View {
        let m = model.liveMetrics
        let settling = (m?.hrBpm == nil) && (m?.contact ?? false)
        return VStack(alignment: .leading, spacing: MV.s16) {
            SectionHeader(title: "Reading")

            // Hero heart-rate row with its prominent range gauge.
            VStack(alignment: .leading, spacing: MV.s8) {
                HStack(alignment: .center, spacing: MV.s16) {
                    IconBadge(systemName: "heart.fill", tint: MV.magenta, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        if settling {
                            HStack(spacing: MV.s8) {
                                ProgressView().tint(MV.accent)
                                Text("Settling…").font(.subheadline).foregroundStyle(MV.inkMuted)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(Fmt.bpm(m?.hrBpm))
                                    .font(MV.number(36)).foregroundStyle(MV.ink)
                                    .contentTransition(.numericText())
                                Text("bpm").font(.subheadline.weight(.medium)).foregroundStyle(MV.inkMuted)
                            }
                        }
                        Text("Heart rate").font(.caption).foregroundStyle(MV.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
                MetricGauges.heartRate(m?.hrBpm)
            }

            Divider().background(MV.separator)

            // Secondary readings, each with its own "where this sits" gauge.
            if model.showsSpo2 {
                readingRow("Blood oxygen", Fmt.opt(m?.spo2Pct, decimals: 0), "%",
                           gauge: MetricGauges.spo2(m?.spo2Pct))
            }
            readingRow("Respiratory rate", Fmt.bpm(m?.respRateBpm), "br/min",
                       note: isDevice ? nil : "Available with the MoniVitals device",
                       gauge: MetricGauges.respiratoryRate(m?.respRateBpm))
            readingRow("HRV (RMSSD)", Fmt.ms(m?.rmssdMs), "ms",
                       note: isDevice
                           ? "HRV is very personal and varies with age — trends matter more than one number."
                           : "Available with the MoniVitals device",
                       gauge: MetricGauges.hrv(m?.rmssdMs))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    /// A full-width labelled reading: title + value/unit on one line, a slim range
    /// gauge beneath, and an optional non-judgmental note.
    private func readingRow(_ title: String, _ value: String, _ unit: String,
                            note: String? = nil, gauge: RangeGauge) -> some View {
        VStack(alignment: .leading, spacing: MV.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(MV.inkMuted)
                Spacer(minLength: MV.s8)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(MV.number(20)).foregroundStyle(MV.ink)
                        .contentTransition(.numericText())
                    Text(unit).font(.caption2).foregroundStyle(MV.inkMuted)
                }
            }
            gauge
            if let note {
                Text(note)
                    .font(.caption2).foregroundStyle(MV.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var saveCard: some View {
        let hasEstimate = model.liveMetrics?.hrBpm != nil
        let needsProfile = model.currentSubjectCode == nil
        return VStack(alignment: .leading, spacing: MV.s12) {
            SectionHeader(title: "Save this reading", subtitle: "Keep it for a profile")

            Button {
                showSubjectSheet = true
            } label: {
                HStack(spacing: MV.s12) {
                    IconBadge(systemName: "person.crop.circle", tint: MV.navy, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profile").font(.caption).foregroundStyle(MV.inkMuted)
                        Text(model.currentSubjectCode ?? "Choose a profile")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(MV.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            Picker("Moment", selection: $label) {
                ForEach(SessionLabel.allCases, id: \.self) { l in
                    Text(l.rawValue.capitalized).tag(l)
                }
            }
            .pickerStyle(.menu)
            .tint(MV.accent)
            .disabled(model.recording != nil)

            if model.recording == nil {
                Button {
                    Haptics.commit()
                    model.startRecording(label: label, notes: notes)
                } label: {
                    Label("Start saving", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(needsProfile || !hasEstimate)
                if needsProfile {
                    Text("Choose a profile before saving.")
                        .font(.caption2)
                        .foregroundStyle(MV.inkMuted)
                } else if !hasEstimate {
                    Text("Hold still until heart rate appears.")
                        .font(.caption2)
                        .foregroundStyle(MV.inkMuted)
                }
            } else {
                HStack(spacing: MV.s8) {
                    RecordingDot()
                    Text("Saving · \(Fmt.duration(model.recordDurationMs))")
                        .font(.caption).foregroundStyle(MV.inkMuted)
                    Spacer()
                }
                Button {
                    Haptics.success()
                    model.stopRecording()
                } label: {
                    Label("Finish", systemImage: "stop.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle(fill: MV.bad))
            }
        }
        .mvCard()
    }
}

/// A small red "saving" dot that softly pulses (static under Reduce Motion).
private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(MV.bad)
            .frame(width: 8, height: 8)
            .opacity(pulse && !reduceMotion ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Profile picker / creator

struct SubjectPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var newCode = ""
    @State private var ageBand = "20-29"
    @State private var notes = ""

    private let ageBands = ["<20", "20-29", "30-39", "40-49", "50-59", "60+"]

    var body: some View {
        NavigationStack {
            List {
                if !model.subjects.isEmpty {
                    Section("Your profiles") {
                        ForEach(model.subjects) { subject in
                            Button {
                                model.selectSubject(subject.code)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(subject.code).foregroundStyle(MV.ink)
                                    Spacer()
                                    if model.currentSubjectCode == subject.code {
                                        Image(systemName: "checkmark").foregroundStyle(MV.accent)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(MV.surface)
                }

                Section("New profile (no personal details)") {
                    TextField("Nickname, e.g. Me", text: $newCode)
                        .textInputAutocapitalization(.words)
                    Picker("Age band", selection: $ageBand) {
                        ForEach(ageBands, id: \.self) { Text($0) }
                    }
                    TextField("Notes (optional)", text: $notes)
                    Button {
                        let code = newCode.trimmingCharacters(in: .whitespaces)
                        guard !code.isEmpty else { return }
                        let subject = Subject(code: code, ageBand: ageBand, sex: nil, notes: notes,
                                              createdAt: ISO8601DateFormatter().string(from: Date()))
                        model.saveSubject(subject)
                        model.selectSubject(code)
                        dismiss()
                    } label: {
                        Label("Add profile", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(MV.surface)
            }
            .scrollContentBackground(.hidden)
            .background(MV.bg)
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
            .onAppear { model.refreshSubjects() }
        }
    }
}
