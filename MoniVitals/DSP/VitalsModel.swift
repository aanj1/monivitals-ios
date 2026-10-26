//
//  VitalsModel.swift
//  MoniVitals
//
//  The on-device model that turns camera pulse packets into a `MetricsSnapshot`.
//  This is the seam where a learned model could later replace the deterministic
//  signal processing; today it is backed by the DSP `MetricsEngine`, exposed
//  behind a swappable contract.
//
//  MoniVitals works everything out on your phone — nothing leaves the device.
//

import Foundation

/// A swappable pulse model. Implementations ingest pulse packets + movement and
/// produce a fused reading on demand.
protocol VitalsModel: AnyObject {
    /// Human-readable model identity (shown in the UI).
    var name: String { get }
    /// Recent detected pulse-beat times (µs) for waveform markers.
    var recentFeet: [Double] { get }

    func setMotionThresh(_ thresh: Double)
    func setMotion(_ level: Int)
    func ingestPpg(_ p: PpgPacket)

    /// Run inference and return the fused reading at the given timestamp.
    func infer(at tUs: Double) -> MetricsSnapshot

    func reset()
}

/// The default on-device model: the deterministic pulse pipeline.
extension MetricsEngine: VitalsModel {
    var name: String { "MoniVitals on-device model v1" }

    func infer(at tUs: Double) -> MetricsSnapshot { snapshot(tUs) }
}
