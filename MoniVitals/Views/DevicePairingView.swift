//
//  DevicePairingView.swift
//  MoniVitals
//
//  The pairing flow for the optional MoniVitals hardware device. Scan for nearby
//  "MoniVitals-XXXX" sensors, show them as rows (name + signal strength), and tap
//  one to connect. Mirrors the measurement screen's warm, card-based language.
//
//  Bluetooth off / not permitted / unavailable (e.g. the Simulator, which has no
//  BLE radio) shows a gentle "Bluetooth isn't available here" state — never a crash.
//

import SwiftUI

struct DevicePairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MV.s16) {
                    switch model.connectionState {
                    case .measuring:
                        connectedCard
                    case .unsupported:
                        unavailableCard
                    case .starting:
                        scanningHeader
                        deviceList
                    case .disconnected:
                        idleHeader
                        deviceList
                    }
                }
                .padding(MV.s16)
            }
            .background(MV.bg)
            .navigationTitle("MoniVitals device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("MoniVitals device").font(.headline).foregroundStyle(MV.navy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { model.startDeviceScan() }
        .onDisappear {
            // Keep a live connection when leaving; only stop an idle scan.
            if model.connectionState != .measuring { model.stopDeviceScan() }
        }
    }

    // MARK: - Headers

    private var scanningHeader: some View {
        HStack(spacing: MV.s12) {
            ProgressView().tint(MV.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.stateMessage ?? "Looking for your MoniVitals device…")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                Text("Make sure the sensor is powered on and nearby.")
                    .font(.caption).foregroundStyle(MV.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    private var idleHeader: some View {
        VStack(alignment: .leading, spacing: MV.s12) {
            HStack(spacing: MV.s12) {
                IconBadge(systemName: "sensor.tag.radiowaves.forward.fill",
                          tint: MV.navy, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your MoniVitals device")
                        .font(.headline).foregroundStyle(MV.ink)
                    Text(model.stateMessage ??
                         "Power on the sensor, then tap Scan to find it nearby.")
                        .font(.caption).foregroundStyle(MV.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button {
                Haptics.commit()
                model.startDeviceScan()
            } label: {
                Label("Scan for devices", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    // MARK: - Device list

    @ViewBuilder
    private var deviceList: some View {
        if model.discoveredDevices.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: MV.s8) {
                SectionHeader(title: "Nearby devices")
                VStack(spacing: MV.s8) {
                    ForEach(model.discoveredDevices) { device in
                        DeviceRow(device: device) {
                            Haptics.commit()
                            model.connectDevice(device)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MV.s12) {
            if model.scanningForDevices {
                ProgressView().controlSize(.large).tint(MV.accent)
                Text("Searching for MoniVitals devices…")
                    .font(.subheadline).foregroundStyle(MV.inkMuted)
            } else {
                IconBadge(systemName: "magnifyingglass", tint: MV.inkMuted, size: 40)
                Text("No devices found yet")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                Text("Bring the sensor closer and tap Scan again.")
                    .font(.caption).foregroundStyle(MV.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MV.s24)
        .mvCard()
    }

    // MARK: - Connected / unavailable

    private var connectedCard: some View {
        VStack(alignment: .leading, spacing: MV.s12) {
            HStack(spacing: MV.s12) {
                IconBadge(systemName: "checkmark.seal.fill", tint: MV.good, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                        .font(.headline).foregroundStyle(MV.ink)
                    Text("Your MoniVitals device is streaming. Open Measure to see your reading.")
                        .font(.caption).foregroundStyle(MV.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let dm = model.deviceMetrics {
                HStack(spacing: MV.s16) {
                    liveStat("Heart rate", Fmt.bpm(dm.hrBpm), "bpm")
                    liveStat("SpO₂", Fmt.opt(dm.spo2Pct, decimals: 0), "%")
                    liveStat("Contact", dm.contact ? "Yes" : "No", "")
                }
            }
            Button(role: .destructive) {
                Haptics.warning()
                model.disconnectDevice()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .buttonStyle(PrimaryButtonStyle(fill: MV.bad))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mvCard()
    }

    private func liveStat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(MV.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(MV.number(18)).foregroundStyle(MV.ink)
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(MV.inkMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableCard: some View {
        VStack(spacing: MV.s16) {
            ZStack {
                Circle().fill(MV.warn.opacity(0.10)).frame(width: 92, height: 92)
                Image(systemName: "wave.3.right.circle")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(MV.warn)
            }
            VStack(spacing: MV.s4) {
                Text("Bluetooth isn't available here")
                    .font(.title3.weight(.semibold)).foregroundStyle(MV.ink)
                    .multilineTextAlignment(.center)
                Text(model.stateMessage ??
                     "Turn on Bluetooth on a real iPhone to connect your MoniVitals device.")
                    .font(.subheadline).foregroundStyle(MV.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MV.s32)
        .padding(.horizontal, MV.s8)
        .mvCard()
    }
}

/// One tappable device row: name, a signal-strength glyph from RSSI, and a chevron.
private struct DeviceRow: View {
    let device: DiscoveredDevice
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: MV.s12) {
                IconBadge(systemName: "sensor.tag.radiowaves.forward.fill",
                          tint: MV.magenta, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(MV.ink)
                    Text(signalLabel)
                        .font(.caption2).foregroundStyle(MV.inkMuted)
                }
                Spacer()
                Image(systemName: signalGlyph).foregroundStyle(MV.good)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(MV.inkMuted)
            }
            .padding(MV.s12)
            .background(
                RoundedRectangle(cornerRadius: MV.rTile, style: .continuous).fill(MV.surface))
            .overlay(
                RoundedRectangle(cornerRadius: MV.rTile, style: .continuous)
                    .stroke(MV.separator, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .accessibilityLabel("\(device.name), \(signalLabel)")
    }

    private var signalLabel: String { "Signal \(device.rssi) dBm" }

    private var signalGlyph: String {
        switch device.rssi {
        case ..<(-85): return "cellularbars"  // weak
        case ..<(-70): return "wifi.exclamationmark"
        default: return "wifi"
        }
    }
}
