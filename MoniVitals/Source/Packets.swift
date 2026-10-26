//
//  Packets.swift
//  MoniVitals
//
//  Typed representation of the camera pulse (PPG) samples that flow from the
//  capture layer to the DSP and the live waveform. Only the pulse stream exists
//  now — every reading is worked out on your phone from the camera and motion.
//
//  `tUs` is the timestamp (microseconds) of the first sample in the packet.
//

import Foundation

/// The one live sample stream: the pulse read from the camera.
enum StreamKind: String, CaseIterable, Codable {
    case ppg
}

/// A block of pulse samples read from the camera, with per-block timing.
///
/// `red` carries the true (non-inverted) red-channel brightness (used for contact/
/// DC); `green` carries the green-channel brightness, which holds the pulse ripple.
/// Both are `Double` — the pulse ripple is a fraction of one brightness count, so
/// quantizing to integers here would erase the very signal the DSP reads. Device
/// integers (BLE) convert losslessly. `ir` is left empty (phone cameras have no
/// infrared channel). `sampleRateHz` is the capture rate — locked to a steady 30 fps.
struct PpgPacket {
    var seq: Int
    var tUs: Double
    var sampleRateHz: Int
    var green: [Double]
    var red: [Double]
    var ir: [Double]
    /// Real per-sample timestamps (µs), one per green/red sample. The camera bridge
    /// fills this with each frame's true PTS so fps drift / drops don't scale the
    /// rate; empty on the BLE path (there `tUs` + `sampleRateHz` reconstruct times).
    var timesUs: [Double] = []
}

/// A light status update from the capture layer: how good the fingertip contact
/// looks (0…100) and the measured frame rate.
struct CaptureStatus {
    var contactQuality: Int
    var fps: Int
    var tUs: Double
}

/// Vitals the MoniVitals hardware device reports directly over BLE (as opposed to
/// the phone-side DSP working them out from the raw pulse). The camera source never
/// emits this; only `BleSource` does. Any field may be `nil` when the device has
/// not reported it yet (e.g. SpO₂ needs a moment of clean signal to settle).
struct DeviceMetrics {
    /// Heart rate the device measured, in beats per minute (nil = not reported).
    var hrBpm: Double?
    /// Blood-oxygen estimate the device measured, 0…100 % (nil = not reported).
    var spo2Pct: Double?
    /// Whether a fingertip is on the sensor (authoritative device contact flag).
    var contact: Bool
}
