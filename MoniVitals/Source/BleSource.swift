//
//  BleSource.swift
//  MoniVitals
//
//  Reads your pulse from a MoniVitals hardware device (an ESP32-C3 + MAX30102
//  finger sensor) over Bluetooth Low Energy. It's the second measurement source
//  alongside the rear-camera path — it fills the SAME pulse buffers the camera
//  fills, so every downstream screen and the DSP are reused unchanged.
//
//  The device advertises as "MoniVitals-XXXX" and streams:
//    • raw PPG waveform (int16)      → the pulse ring buffer + on-device DSP,
//    • heart rate + SpO₂ + contact   → published as `DeviceMetrics`.
//
//  It never bonds and never asks for a PIN — plaintext notify characteristics.
//
//  When Bluetooth is off, not permitted, or simply unavailable (for example in the
//  Simulator, which has no BLE radio), the source settles into the friendly
//  `.unsupported` state with warm copy instead of crashing.
//
//  The pure `BleParsers` decoders at the bottom carry no CoreBluetooth types, so
//  they are exercised directly by unit tests with synthetic byte buffers.
//

import Combine
import CoreBluetooth
import Foundation

// MARK: - GATT identifiers

/// Every UUID the MoniVitals device exposes. Custom characteristics share the base
/// `425400XX-5441-4542-4F58-3B9A78563412` where XX is the characteristic id.
enum MoniVitalsBLE {
    /// Advertised device-name prefix used to filter the scan.
    static let namePrefix = "MoniVitals"

    // Standard Bluetooth SIG services / characteristics.
    static let heartRateService  = CBUUID(string: "180D")
    static let heartRateMeasure  = CBUUID(string: "2A37")   // read + notify
    static let pulseOxService    = CBUUID(string: "1822")
    static let plxContinuous     = CBUUID(string: "2A5F")   // read + notify

    // Custom 128-bit service + characteristics.
    static let customService = CBUUID(string: "42540001-5441-4542-4F58-3B9A78563412")
    static let quality       = CBUUID(string: "42540002-5441-4542-4F58-3B9A78563412") // read + notify
    static let ppg           = CBUUID(string: "42540006-5441-4542-4F58-3B9A78563412") // read + notify
    static let command       = CBUUID(string: "42540007-5441-4542-4F58-3B9A78563412") // write

    /// Command payload: `[0x02, on]` — 1 starts streaming, 0 stops it.
    static func streamCommand(on: Bool) -> Data { Data([0x02, on ? 0x01 : 0x00]) }

    /// Services we scan for (custom + both standard vitals services).
    static let scanServices = [customService, heartRateService, pulseOxService]
}

// MARK: - Discovered peripheral (for the pairing list)

/// A device seen during scanning, shown as a row in the pairing screen.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID          // peripheral.identifier
    let name: String
    var rssi: Int

    static func == (l: DiscoveredDevice, r: DiscoveredDevice) -> Bool { l.id == r.id }
}

// MARK: - BleSource

final class BleSource: NSObject, DataSource {
    let events = DataSourceEvents()

    private(set) var stateValue: ConnectionState = .disconnected
    var state: ConnectionState { stateValue }

    /// Devices found during the current scan (name + live RSSI), newest RSSI wins.
    /// Published on the main thread so the pairing screen can bind to it.
    let discovered = CurrentValueSubject<[DiscoveredDevice], Never>([])
    /// True while a scan is in flight (drives the pairing-screen spinner).
    let scanning = CurrentValueSubject<Bool, Never>(false)
    /// Fires (on main) when the PPG sequence numbers show dropped notifications,
    /// so the app can reset beat-sensitive DSP state (HRV must not span the hole).
    let streamGap = PassthroughSubject<Void, Never>()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?

    /// The device the user asked to connect to (nil while just scanning).
    private var pendingPeripheral: CBPeripheral?

    // Packet assembly for the raw int16 PPG stream. The device sends ~100 sps; we
    // stamp packets with a monotonic device clock so the DSP timing matches camera.
    private var seq = 0
    private var startUptime: TimeInterval = 0
    private let ppgSampleRateHz = 100
    /// Running timestamp (µs) for the NEXT PPG sample. Advancing this by
    /// count·(1e6/rate) per packet reconstructs a perfectly contiguous 100 sps
    /// timeline for the DSP, immune to BLE notify jitter. Re-snapped to the wall
    /// clock on (re)connect or if it drifts too far (a stall / dropped packets).
    private var ppgClockUs: Double?
    /// The device's last PPG notification sequence byte (new firmware prepends a
    /// uint8 seq that wraps 255→0). nil until the first stamped packet arrives.
    private var lastDeviceSeq: Int?

    /// Sticky contact so a single dropped-contact reading doesn't flap the UI.
    private var lastContact = false

    /// Fires if a connect attempt doesn't link up in time — CoreBluetooth's
    /// `connect` has no built-in timeout, so a device that walked out of range
    /// would otherwise leave the UI stuck on "Connecting…" forever.
    private var connectTimeout: DispatchWorkItem?

    /// The pairing screen wants to be scanning — survives a Bluetooth off→on toggle
    /// so scanning resumes automatically (unlike the transient `scanning` flag).
    private var wantsScan = false
    /// Flips an endless "searching…" spinner into a "no devices found" state.
    private var scanWatchdog: DispatchWorkItem?

    private func setState(_ s: ConnectionState, detail: ConnectionDetail? = nil) {
        stateValue = s
        DispatchQueue.main.async { self.events.connection.send((s, detail)) }
    }

    // MARK: - Lifecycle

    override init() {
        super.init()
        // Creating the central triggers `centralManagerDidUpdateState`, where we
        // learn whether Bluetooth is actually usable.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - DataSource

    func connect() {
        // Bring the radio up / re-check availability, then start scanning if we can.
        startScan()
    }

    func disconnect() {
        connectTimeout?.cancel(); connectTimeout = nil
        stopScan()
        if let p = peripheral {
            // Ask the device to stop streaming, then drop the link.
            if let c = commandChar, p.state == .connected {
                p.writeValue(MoniVitalsBLE.streamCommand(on: false), for: c, type: .withResponse)
            }
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        pendingPeripheral = nil
        commandChar = nil
        setState(.disconnected)
    }

    func start() {
        // Streaming auto-starts on subscribe; nothing extra to do once measuring.
        guard let p = peripheral, let c = commandChar, p.state == .connected else { return }
        p.writeValue(MoniVitalsBLE.streamCommand(on: true), for: c, type: .withResponse)
    }

    func stop() {
        guard let p = peripheral, let c = commandChar, p.state == .connected else { return }
        p.writeValue(MoniVitalsBLE.streamCommand(on: false), for: c, type: .withResponse)
    }

    // MARK: - Scanning + connecting (driven by the pairing UI)

    /// Begin (or resume) scanning for nearby MoniVitals devices. Safe to call before
    /// Bluetooth is ready — it defers until `poweredOn`.
    func startScan() {
        wantsScan = true
        discovered.send([])
        guard central.state == .poweredOn else {
            // Reflect why we can't scan (off / unauthorized / unavailable).
            applyRadioState(central.state)
            return
        }
        scanning.send(true)
        setState(.starting, detail: ConnectionDetail(message: "Looking for your MoniVitals device…"))
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // Endless "searching…" spinner → "no devices found" after 20s of nothing.
        scanWatchdog?.cancel()
        let watch = DispatchWorkItem { [weak self] in
            guard let self, self.scanning.value, self.discovered.value.isEmpty else { return }
            self.stopScan()
            self.setState(.disconnected, detail: ConnectionDetail(
                message: "No devices found. Make sure your MoniVitals device is on and nearby, then tap Scan."))
        }
        scanWatchdog = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: watch)
    }

    func stopScan() {
        wantsScan = false
        scanWatchdog?.cancel()
        scanWatchdog = nil
        if central.state == .poweredOn { central.stopScan() }
        scanning.send(false)
    }

    /// Connect to a device the user tapped in the pairing list.
    func connect(to device: DiscoveredDevice) {
        // Don't start a second connection while one is pending/connected — tapping
        // another row would overwrite pendingPeripheral and orphan the first.
        guard pendingPeripheral == nil, peripheral == nil else { return }
        guard central.state == .poweredOn else {
            setState(.disconnected, detail: ConnectionDetail(message: "Bluetooth is off — turn it on and try again."))
            return
        }
        guard let p = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            setState(.disconnected, detail: ConnectionDetail(message: "Couldn't reach that device — tap Scan and try again."))
            return
        }
        stopScan()
        pendingPeripheral = p
        p.delegate = self
        setState(.starting, detail: ConnectionDetail(message: "Connecting to \(device.name)…"))
        central.connect(p, options: nil)
        // CoreBluetooth's connect never times out on its own; arm our own so an
        // out-of-range device can't leave the user stuck on "Connecting…".
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingPeripheral else { return }
            self.central.cancelPeripheralConnection(pending)
            self.pendingPeripheral = nil
            self.setState(.disconnected, detail: ConnectionDetail(
                message: "Couldn't connect — bring the device closer and try again."))
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    // MARK: - internals

    private func deviceNowUs() -> Double {
        (ProcessInfo.processInfo.systemUptime - startUptime) * DSPConstants.usPerS
    }

    /// Translate the radio's power/authorization state into a friendly source state.
    private func applyRadioState(_ s: CBManagerState) {
        switch s {
        case .poweredOn:
            break // handled by startScan
        case .poweredOff:
            setState(.unsupported, detail: ConnectionDetail(
                message: "Bluetooth is off. Turn it on to connect your MoniVitals device."))
        case .unauthorized:
            setState(.unsupported, detail: ConnectionDetail(
                message: "Turn on Bluetooth access for MoniVitals in Settings to connect your device."))
        case .unsupported:
            setState(.unsupported, detail: ConnectionDetail(
                message: "Bluetooth isn't available here. Connect your MoniVitals device from a real iPhone."))
        case .resetting, .unknown:
            setState(.starting, detail: ConnectionDetail(message: "Getting Bluetooth ready…"))
        @unknown default:
            setState(.unsupported, detail: ConnectionDetail(
                message: "Bluetooth isn't available right now."))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleSource: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Radio came up — if the pairing screen still wants to scan, resume.
            // Gate on `wantsScan` (not the transient `scanning`, which radio-off cleared).
            if wantsScan { startScan() }
        } else {
            scanning.send(false)
            applyRadioState(central.state)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Prefer the advertised local name, fall back to the peripheral name.
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // Accept devices matching our name prefix OR advertising the custom service.
        let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let matchesName = name.hasPrefix(MoniVitalsBLE.namePrefix)
        let matchesService = advServices.contains(MoniVitalsBLE.customService)
        guard matchesName || matchesService else { return }

        let display = name.isEmpty ? "MoniVitals device" : name
        let device = DiscoveredDevice(id: peripheral.identifier, name: display, rssi: RSSI.intValue)
        var list = discovered.value
        if let idx = list.firstIndex(where: { $0.id == device.id }) {
            list[idx].rssi = device.rssi
        } else {
            list.append(device)
        }
        // Strongest signal first.
        list.sort { $0.rssi > $1.rssi }
        // Found something — cancel the "no devices" watchdog.
        scanWatchdog?.cancel(); scanWatchdog = nil
        DispatchQueue.main.async { self.discovered.send(list) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeout?.cancel(); connectTimeout = nil
        self.peripheral = peripheral
        pendingPeripheral = nil
        peripheral.delegate = self
        setState(.starting, detail: ConnectionDetail(message: "Setting up your device…"))
        peripheral.discoverServices(MoniVitalsBLE.scanServices)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel(); connectTimeout = nil
        pendingPeripheral = nil
        setState(.disconnected, detail: ConnectionDetail(
            message: "Couldn't connect. Bring the device closer and try again."))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        commandChar = nil
        lastContact = false
        ppgClockUs = nil
        lastDeviceSeq = nil
        // A clean user-initiated disconnect leaves no error; a dropout carries one.
        if error != nil {
            setState(.disconnected, detail: ConnectionDetail(
                message: "Your MoniVitals device disconnected. Tap Pair to scan and reconnect."))
        } else {
            setState(.disconnected)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleSource: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case MoniVitalsBLE.heartRateService:
                peripheral.discoverCharacteristics([MoniVitalsBLE.heartRateMeasure], for: service)
            case MoniVitalsBLE.pulseOxService:
                peripheral.discoverCharacteristics([MoniVitalsBLE.plxContinuous], for: service)
            case MoniVitalsBLE.customService:
                peripheral.discoverCharacteristics(
                    [MoniVitalsBLE.quality, MoniVitalsBLE.ppg, MoniVitalsBLE.command], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case MoniVitalsBLE.heartRateMeasure,
                 MoniVitalsBLE.plxContinuous,
                 MoniVitalsBLE.ppg,
                 MoniVitalsBLE.quality:
                peripheral.setNotifyValue(true, for: c)
            case MoniVitalsBLE.command:
                commandChar = c
                // Start the stream now that we have the command handle.
                peripheral.writeValue(MoniVitalsBLE.streamCommand(on: true),
                                      for: c, type: .withResponse)
            default:
                break
            }
        }

        // Once the PPG stream is subscribed we consider ourselves live.
        if service.uuid == MoniVitalsBLE.customService {
            seq = 0
            ppgClockUs = nil
            lastDeviceSeq = nil
            startUptime = ProcessInfo.processInfo.systemUptime
            setState(.measuring)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        switch characteristic.uuid {
        case MoniVitalsBLE.ppg:
            let payload = BleParsers.ppgPayload(bytes)
            if let deviceSeq = payload.seq {
                // Sequence gap = notifications were dropped. Re-snap the sample
                // clock so the missing time isn't glued out of the timeline, and
                // tell the app so beat-sensitive DSP state is reset (an RR
                // interval must never silently span the hole).
                if let last = lastDeviceSeq, deviceSeq != (last + 1) & 0xFF {
                    ppgClockUs = nil
                    DispatchQueue.main.async { self.streamGap.send() }
                }
                lastDeviceSeq = deviceSeq
            }
            let samples = payload.samples
            guard !samples.isEmpty else { return }
            // The device already inverts so a pulse deflects upward, matching the
            // camera's red channel. Feed both green + red with the same waveform so
            // the DSP (which reads green for beats, red for quality) sees the pulse.
            let mag = samples.map { Double($0) + 32768.0 }
            // Contiguous timeline: advance a running sample clock by exactly
            // count·(1e6/rate). Snap to the wall clock on the first packet or if
            // it drifts >0.5 s (a stall/reconnect), so the DSP never sees a gap
            // or a compressed window from BLE notify jitter.
            let now = deviceNowUs()
            let dtUs = DSPConstants.usPerS / Double(ppgSampleRateHz)
            var t = ppgClockUs ?? now
            if abs(t - now) > 500_000 { t = now }
            let packet = PpgPacket(seq: seq, tUs: t,
                                   sampleRateHz: ppgSampleRateHz,
                                   green: mag, red: mag, ir: [])
            ppgClockUs = t + Double(samples.count) * dtUs
            seq = (seq + 1) & 0xffff
            DispatchQueue.main.async { self.events.ppg.send(packet) }

        case MoniVitalsBLE.heartRateMeasure:
            let hr = BleParsers.heartRate(bytes)
            emitDeviceMetrics(hrBpm: hr.bpm, spo2Pct: nil, contact: hr.contact ?? lastContact)

        case MoniVitalsBLE.plxContinuous:
            let spo2 = BleParsers.spo2Percent(bytes)
            emitDeviceMetrics(hrBpm: nil, spo2Pct: spo2, contact: lastContact)

        case MoniVitalsBLE.quality:
            let q = BleParsers.quality(bytes)
            lastContact = q.contact
            emitDeviceMetrics(hrBpm: nil, spo2Pct: nil, contact: q.contact)

        default:
            break
        }
    }

    /// Publish a device-metrics update, remembering contact so partial updates
    /// (HR-only or SpO₂-only notifications) still carry the latest contact flag.
    private func emitDeviceMetrics(hrBpm: Double?, spo2Pct: Double?, contact: Bool) {
        lastContact = contact
        let m = DeviceMetrics(hrBpm: hrBpm, spo2Pct: spo2Pct, contact: contact)
        DispatchQueue.main.async { self.events.deviceMetrics.send(m) }
    }
}

// MARK: - Pure parsers (unit-tested with synthetic byte buffers)

/// Stateless decoders for each MoniVitals characteristic. No CoreBluetooth types
/// cross this boundary, so the byte→value math is fully unit-testable.
enum BleParsers {

    /// Heart Rate Measurement `0x2A37`: `[flags, hr_lo, hr_hi?]`.
    /// flags bit0 (0x01) = HR is uint16 (else uint8); flags bit1 (0x02) = sensor
    /// contact *detected* (status); flags bit2 (0x04) = sensor contact *supported*.
    /// `bpm == 0` with contact clear = finger removed.
    static func heartRate(_ bytes: [UInt8]) -> (bpm: Double?, contact: Bool?) {
        guard bytes.count >= 2 else { return (nil, nil) }
        let flags = bytes[0]
        let isUInt16 = (flags & 0x01) != 0
        let bpmRaw: Int
        if isUInt16 {
            guard bytes.count >= 3 else { return (nil, nil) }
            bpmRaw = Int(bytes[1]) | (Int(bytes[2]) << 8)
        } else {
            bpmRaw = Int(bytes[1])
        }
        // Contact: bit2 (0x04) = "sensor contact supported", bit1 (0x02) = "contact
        // detected". Only trust the detected bit when the sensor advertises support;
        // otherwise contact is unknown (nil).
        var contact: Bool? = nil
        if (flags & 0x04) != 0 {
            contact = (flags & 0x02) != 0
        }
        // bpm 0 = finger removed / not measuring → report no HR.
        let bpm: Double? = bpmRaw > 0 ? Double(bpmRaw) : nil
        return (bpm, contact)
    }

    /// PLX Continuous Measurement `0x2A5F`: `[flags, spo2_sfloat_lo, spo2_sfloat_hi, ...]`.
    /// SpO₂% is an IEEE-11073 16-bit SFLOAT. Returns nil when 0 (not reported) or
    /// implausible. Clamps a valid reading to 70…100 %.
    static func spo2Percent(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3 else { return nil }
        let raw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        guard let v = sfloat(raw), v > 0 else { return nil }
        // Reject clearly implausible readings; allow mild overshoot past 100 (sensor
        // rounding) and clamp it back into the reportable 70…100 % range.
        guard v.isFinite, v >= 50, v <= 110 else { return nil }
        return min(100, max(70, v))
    }

    /// Quality `42540002`: `[perfusion_index (0.1% units), contact (0|1)]`.
    /// The contact byte is authoritative. Perfusion index is returned in % (÷10).
    static func quality(_ bytes: [UInt8]) -> (perfusionPct: Double, contact: Bool) {
        guard bytes.count >= 2 else { return (0, false) }
        let perfusion = Double(bytes[0]) / 10.0
        let contact = bytes[1] != 0
        return (perfusion, contact)
    }

    /// PPG `42540006` notification payload. Current firmware prepends a uint8
    /// sequence number that increments per notification and wraps 255→0:
    /// `[seq_u8, int16 samples…]` — always an odd total length (1 + 2n). An
    /// even-length payload can only be the legacy format (bare int16 array, no
    /// seq byte), so it is parsed as legacy and `seq` comes back nil.
    static func ppgPayload(_ bytes: [UInt8]) -> (seq: Int?, samples: [Int16]) {
        guard !bytes.isEmpty else { return (nil, []) }
        if bytes.count % 2 == 1 {
            return (Int(bytes[0]), ppgSamples(Array(bytes.dropFirst())))
        }
        return (nil, ppgSamples(bytes))
    }

    /// PPG sample block: little-endian `int16` array (up to 50 samples/notify).
    /// Trailing odd byte (if any) is ignored.
    static func ppgSamples(_ bytes: [UInt8]) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let lo = UInt16(bytes[i])
            let hi = UInt16(bytes[i + 1])
            out.append(Int16(bitPattern: lo | (hi << 8)))
            i += 2
        }
        return out
    }

    /// Decode an IEEE-11073 16-bit SFLOAT (4-bit signed exponent, 12-bit signed
    /// mantissa). Returns nil for the reserved NaN / NRes / +∞ / −∞ specials.
    static func sfloat(_ raw: UInt16) -> Double? {
        // Reserved specials are defined by the 12-bit mantissa pattern regardless
        // of the exponent, so mask the mantissa out first, then test it.
        let mantissaBits = Int(raw & 0x0FFF)
        switch mantissaBits {
        case 0x07FF, 0x0800, 0x07FE, 0x0801, 0x0802:
            return nil // NaN, NRes, +INF, reserved, -INF
        default: break
        }
        var mantissa = mantissaBits
        if mantissa >= 0x0800 { mantissa -= 0x1000 } // sign-extend 12-bit
        var exponent = Int((raw >> 12) & 0x000F)
        if exponent >= 0x0008 { exponent -= 0x0010 } // sign-extend 4-bit
        return Double(mantissa) * pow(10.0, Double(exponent))
    }
}
