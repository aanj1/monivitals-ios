//
//  Models.swift
//  MoniVitals
//
//  Local-first data model. Profiles are identified only by a non-identifying
//  code. All persisted types are Codable so they round-trip to disk and to the
//  optional cloud backup.
//

import Foundation

enum SessionLabel: String, Codable, CaseIterable {
    case rest
    case seated
    case walking
    case postExercise = "post-exercise"
    case other
}

enum AnnotationType: String, Codable, CaseIterable {
    case motionStart = "motion_start"
    case motionStop = "motion_stop"
    case artifact
    case marker
}

/// A profile, identified only by a non-identifying code.
struct Subject: Codable, Identifiable, Equatable {
    var code: String        // primary key, non-identifying
    var ageBand: String
    var sex: String?
    var notes: String
    var createdAt: String   // ISO-8601

    var id: String { code }
}

/// One saved fingertip measurement.
struct Session: Codable, Identifiable, Equatable {
    var id: String
    var subjectCode: String
    var label: SessionLabel
    var startedAt: String
    var endedAt: String?
    var notes: String
}

/// One stored block of pulse samples; timestamps are explicit (monotonic µs).
struct StreamChunk: Codable {
    var id: Int?
    var sessionId: String
    var stream: StreamKind
    var tStartUs: Double
    var sampleRateHz: Int
    var t: [Double]
    // Pulse channels.
    var green: [UInt32]?
    var red: [UInt32]?
    var ir: [UInt32]?
}

/// A persisted readings row.
struct MetricsRecord: Codable {
    var id: Int?
    var sessionId: String
    var tUs: Double
    var hrBpm: Double?
    var respRateBpm: Double?
    var rmssdMs: Double?
    var sdnnMs: Double?
    var signalQuality: Int
    var motion: Int
    /// Blood-oxygen %, present only for readings taken with the MoniVitals device
    /// (the camera source can't estimate SpO₂). Optional + defaulted so older saved
    /// rows decode cleanly and the camera path is unaffected.
    var spo2Pct: Double? = nil
}

/// The last usable visible reading, persisted so Home can show a timestamp and
/// values after the app restarts.
struct LastVitalsSnapshot: Codable, Equatable {
    private static let defaultSafeHeartRateMax = 90.0
    private static let defaultSafeRespRateMax = 20.0
    private static let defaultSafeSpo2Max = 100.0

    var capturedAt: String
    var source: MeasurementSource
    var hrBpm: Double?
    var respRateBpm: Double?
    var rmssdMs: Double?
    var sdnnMs: Double?
    var signalQuality: Int
    var motion: Int
    var spo2Pct: Double?

    var sanitizedForDefaultDisplay: LastVitalsSnapshot {
        var snapshot = self
        snapshot.hrBpm = Self.defaultDisplayValue(hrBpm, max: Self.defaultSafeHeartRateMax)
        snapshot.respRateBpm = Self.defaultDisplayValue(respRateBpm, max: Self.defaultSafeRespRateMax)
        snapshot.spo2Pct = Self.defaultDisplayValue(spo2Pct, max: Self.defaultSafeSpo2Max)
        return snapshot
    }

    private static func defaultDisplayValue(_ value: Double?, max: Double) -> Double? {
        guard let value, value.isFinite, value <= max else { return nil }
        return value
    }
}

/// A timestamped marker.
struct Annotation: Codable, Identifiable {
    var id: Int?
    var sessionId: String
    var tUs: Double
    var type: AnnotationType
    var text: String?
}

/// Where the live pulse comes from: the phone's rear camera (default) or the
/// optional MoniVitals hardware device over Bluetooth.
enum MeasurementSource: String, Codable, CaseIterable {
    case camera
    case device

    /// Warm label for the source picker.
    var title: String {
        switch self {
        case .camera: return "Phone camera"
        case .device: return "Wearable device"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .device: return "sensor.tag.radiowaves.forward.fill"
        }
    }
}

/// How the camera scan is performed: a fingertip pressed over the lens (contact
/// PPG, the default) or a palm held a few centimetres above it. Only meaningful
/// while `measurementSource == .camera`.
enum ScanMode: String, Codable, CaseIterable {
    case finger
    case palm

    var title: String {
        switch self {
        case .finger: return "Fingertip"
        case .palm: return "Palm"
        }
    }

    var systemImage: String {
        switch self {
        case .finger: return "hand.point.up.left.fill"
        case .palm: return "hand.raised.fill"
        }
    }
}

/// App settings (persisted in UserDefaults JSON).
struct AppSettings: Codable, Equatable {
    var motionThresh: Double = DSPConstants.motionThresh
    var theme: Theme = .light
    var consentAccepted: Bool = false
    var cameraGuidanceSeen: Bool = false
    /// Chosen measurement source. Defaults to the camera so existing users (and
    /// older saved settings, via the defaulted decode) keep the camera experience.
    var measurementSource: MeasurementSource = .camera
    /// Camera scan style (fingertip contact vs palm hover).
    var scanMode: ScanMode = .finger

    init() {}

    /// Saved settings can predate newer keys, so every field decodes with a
    /// default — a version upgrade must never throw the whole decode away (which
    /// would reset consent and re-run onboarding).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        motionThresh = try c.decodeIfPresent(Double.self, forKey: .motionThresh) ?? DSPConstants.motionThresh
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .light
        consentAccepted = try c.decodeIfPresent(Bool.self, forKey: .consentAccepted) ?? false
        cameraGuidanceSeen = try c.decodeIfPresent(Bool.self, forKey: .cameraGuidanceSeen) ?? false
        measurementSource = try c.decodeIfPresent(MeasurementSource.self, forKey: .measurementSource) ?? .camera
        scanMode = try c.decodeIfPresent(ScanMode.self, forKey: .scanMode) ?? .finger
    }

    enum Theme: String, Codable, CaseIterable {
        case dark
        case light
        case system
    }
}
