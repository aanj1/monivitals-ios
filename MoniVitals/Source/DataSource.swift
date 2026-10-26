//
//  DataSource.swift
//  MoniVitals
//
//  The single interface the app talks to for the live pulse. The BLE device
//  source (BleSource) implements it, so every screen works through one seam.
//  (Camera mode is driven directly by PPGEngine, not a DataSource.)
//  Packets carry monotonic timestamps (see Timebase.swift).
//
//  Event delivery uses Combine subjects so the AppModel can subscribe with
//  backpressure-free sinks (the high-rate sample handler pushes into non-reactive
//  ring buffers, not @Published state).
//

import Combine
import Foundation

/// Capture lifecycle.
enum ConnectionState: String {
    case disconnected
    /// This phone can't measure right now (e.g. no usable camera, or camera access off).
    case unsupported
    case starting
    case measuring
}

/// Optional detail attached to a state change (friendly copy for the UI).
struct ConnectionDetail {
    var message: String?
}

/// Combine subjects a `DataSource` publishes on. The AppModel subscribes to these.
final class DataSourceEvents {
    let ppg = PassthroughSubject<PpgPacket, Never>()
    /// Fingertip-contact quality + measured frame rate.
    let status = PassthroughSubject<CaptureStatus, Never>()
    let connection = PassthroughSubject<(ConnectionState, ConnectionDetail?), Never>()
    /// Vitals reported directly by a hardware device (HR / SpO₂ / contact).
    /// Only the BLE device source publishes here; the camera never does.
    let deviceMetrics = PassthroughSubject<DeviceMetrics, Never>()
}

/// The capture abstraction implemented by `BleSource`.
protocol DataSource: AnyObject {
    var state: ConnectionState { get }

    /// The Combine event hub for this source.
    var events: DataSourceEvents { get }

    /// Begin capture. Must fail gracefully to `.unsupported` when the transport
    /// is unavailable (e.g. no BLE radio in the Simulator) rather than crash.
    func connect()
    func disconnect()
    func start()
    func stop()
}

/// Shared base providing the event hub + state plumbing.
class BaseDataSource: DataSource {
    let events = DataSourceEvents()
    private(set) var stateValue: ConnectionState = .disconnected

    var state: ConnectionState { stateValue }

    func setState(_ state: ConnectionState, detail: ConnectionDetail? = nil) {
        stateValue = state
        events.connection.send((state, detail))
    }

    // Subclasses override these.
    func connect() {}
    func disconnect() {}
    func start() {}
    func stop() {}
}
