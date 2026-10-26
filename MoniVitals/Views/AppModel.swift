//
//  AppModel.swift
//  MoniVitals
//
//  Central application store (ObservableObject). Orchestrates the camera capture,
//  the live runtime (pulse ring buffer + MetricsEngine + motion), saving
//  measurements, settings, and the optional cloud account.
//
//  High-rate sample data lives in non-reactive `buffers`/`engine` (read directly
//  by the Canvas); only throttled readings, counts, and connection state are
//  @Published here.
//

import AuthenticationServices
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Non-reactive runtime (mutated at full sample rate)
    let buffers = WaveBuffers()
    let engine = MetricsEngine()
    private let motion = MotionMonitor()
    /// Calm-UX camera pipeline (two-stream PPG with short-gap reconstruction).
    /// Drives camera-mode Measure; the device (BLE) path is unaffected.
    let ppg = PPGEngine()

    // MARK: - Settings
    @Published private(set) var settings: AppSettings

    // MARK: - Capture / source
    @Published private(set) var connectionState: ConnectionState = .disconnected
    /// Friendly copy explaining an unsupported/blocked state (e.g. no camera).
    @Published private(set) var stateMessage: String?
    @Published private(set) var measuring = false
    /// Live fingertip-contact quality (0…100) published from the capture layer.
    @Published private(set) var contactQuality = 0
    @Published private(set) var fps = 0

    // MARK: - Measurement source (camera vs MoniVitals device)
    /// The active source kind, mirrored from settings for quick reads in views.
    @Published private(set) var sourceKind: MeasurementSource = .camera
    /// Nearby MoniVitals devices found while pairing (name + RSSI).
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    /// True while the device source is actively scanning.
    @Published private(set) var scanningForDevices = false
    /// Latest vitals reported directly by the hardware device (HR / SpO₂ / contact).
    @Published private(set) var deviceMetrics: DeviceMetrics?
    /// Calm-UX camera state (PPGEngine) mapped to the 3 production states. Camera only.
    @Published private(set) var cameraUIState: PPGUIState = .measuring

    // MARK: - Readings
    @Published private(set) var appMetrics: MetricsSnapshot?
    @Published private(set) var liveMetrics: MetricsSnapshot?
    @Published private(set) var lastVitals: LastVitalsSnapshot?

    // MARK: - Short metric trends (small rolling arrays fed once per tick)
    @Published private(set) var hrTrend: [Double] = []
    @Published private(set) var respTrend: [Double] = []
    private static let trendLength = 60

    // MARK: - Profiles
    @Published private(set) var subjects: [Subject] = []
    @Published private(set) var currentSubjectCode: String?

    // MARK: - Saving a measurement
    @Published private(set) var recording: Session?
    @Published private(set) var recordCounts: [StreamKind: Int] = [.ppg: 0]
    @Published private(set) var recordDurationMs: Double = 0

    // MARK: - Cloud account & sync (optional; app is fully usable signed out)
    @Published private(set) var authState: AuthState?
    @Published private(set) var syncStatus: CloudSyncStatus = .idle
    @Published private(set) var lastSyncAt: Date?

    // MARK: - private
    private var source: DataSource?
    private var recorder: Recorder?
    // Camera-mode: accumulate PPGEngine raw frames into ~6-frame PpgPackets so the
    // existing Recorder/Store/CSV path records real camera data unchanged.
    private var camGreen: [Double] = []
    private var camRed: [Double] = []
    private var camTimes: [Double] = []       // real per-frame PTS (µs), parallel to camGreen/camRed
    private var camPacketStartUs: Double = 0
    private var camSeq = 0
    private var recordingStartedAt: Date?
    /// True once `begin()` has run, so re-appearing roots don't rebuild the source
    /// (in camera mode `source` stays nil, so it can't gate idempotence itself).
    private var began = false
    /// True while the Measure screen is on screen (between `connectCamera()` and
    /// `leaveMeasure()`), so foreground recovery never opens the camera invisibly.
    private var measureScreenActive = false
    private var cancellables = Set<AnyCancellable>()
    private var tickTimer: Timer?
    let store = Store.shared
    private let settingsKey = "monivitals.settings"
    private let lastVitalsKey = "monivitals.lastVitals"

    private static let tickInterval = 0.25

    /// Human-readable identity of the on-device model backing the readings.
    var modelName: String { engine.name }

    init() {
        settings = AppModel.loadSettings(key: "monivitals.settings")
        engine.setMotionThresh(settings.motionThresh)
        sourceKind = settings.measurementSource
        ppg.setScanMode(settings.scanMode)
        subjects = store.listSubjects()
        authState = AuthService.loadPersisted()
        lastSyncAt = SyncService.loadLastSync()
        lastVitals = AppModel.loadLastVitals(key: "monivitals.lastVitals")
    }

    /// The BLE source, when the device source is active (used by the pairing UI).
    var ble: BleSource? { source as? BleSource }

    // MARK: - Settings

    private static func loadSettings(key: String) -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        return AppSettings()
    }

    private static func loadLastVitals(key: String) -> LastVitalsSnapshot? {
        // PHI at rest: read from the encrypted Keychain. Migrate a legacy plaintext
        // UserDefaults blob once, then scrub it.
        if let snapshot = KeychainStore.load(LastVitalsSnapshot.self, account: key) {
            return snapshot.sanitizedForDefaultDisplay
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let legacy = try? JSONDecoder().decode(LastVitalsSnapshot.self, from: data) {
            KeychainStore.save(legacy, account: key)        // move to encrypted store
            UserDefaults.standard.removeObject(forKey: key) // scrub the plaintext copy
            return legacy.sanitizedForDefaultDisplay
        }
        return nil
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        engine.setMotionThresh(s.motionThresh)
        settings = s
    }

    /// First-run consent gate.
    var needsOnboarding: Bool {
        !settings.consentAccepted
    }

    func acceptOnboarding() {
        updateSettings {
            $0.consentAccepted = true
            $0.cameraGuidanceSeen = true
        }
    }

    // MARK: - Capture lifecycle

    /// Bring up the camera capture source. Idempotent. On a device without a usable
    /// camera (e.g. the Simulator) the camera source settles into the friendly
    /// unsupported state rather than crashing.
    func begin() {
        guard !began else { return }
        began = true
        engine.setMotionThresh(settings.motionThresh)
        makeSource(settings.measurementSource)
        // Do NOT open the camera / start scanning here. The camera + its permission
        // prompt (and the BLE scan) belong to the Measure/pairing screens, not app
        // launch — connecting on Home would pop a permission alert over the whole
        // app before the user asks to measure.
    }

    /// Create the capture source for `kind` and wire its events. Tears down any
    /// existing source first. Keeps the camera path the default.
    private func makeSource(_ kind: MeasurementSource) {
        teardownSource()
        sourceKind = kind
        // Clear any stale pulse from the previous source so the live waveform and
        // reporters don't keep showing the old source's data until the next start.
        resetRuntime()
        engine.contactOverride = nil
        engine.motionGatesHrv = (kind == .camera)
        connectionState = .disconnected
        stateMessage = nil
        deviceMetrics = nil
        if kind == .device {
            // The MoniVitals device reports its own contact, so it drives the gate
            // per-tick, skips the camera-tuned quality gate, and skips the
            // phone-motion HRV gate.
            engine.isBleSource = true
            let src = BleSource()
            source = src
            wire(src)
        } else {
            // Camera mode is driven by the calm-UX PPGEngine (not a DataSource) so we
            // never run two camera sessions. Its raw frames bridge into the recorder.
            engine.isBleSource = false
            source = nil
            wireCamera()
        }
    }

    /// Wire the camera calm-UX engine: mirror its 3-state UI + camera availability,
    /// and bridge its raw frames into the existing recorder.
    private func wireCamera() {
        ppg.$uiState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.cameraUIState = s }
            .store(in: &cancellables)
        ppg.$cameraUnavailableMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in
                guard let self else { return }
                if let msg {
                    self.connectionState = .unsupported
                    self.stateMessage = msg
                    self.measuring = false
                } else if self.measuring {
                    self.connectionState = .measuring
                    self.stateMessage = nil
                }
            }
            .store(in: &cancellables)
        ppg.onFrame = { [weak self] frame in self?.ingestCameraFrame(frame) }
    }

    /// Accumulate PPGEngine's real ROI frames into PpgPackets and feed the marker
    /// buffer + (while recording, past the settle window) the recorder. `onFrame`
    /// only ever carries real frames — reconstructed display samples never reach here.
    private func ingestCameraFrame(_ f: PPGFrame) {
        if camGreen.isEmpty { camPacketStartUs = f.tUs }
        camGreen.append(f.green.isFinite ? f.green : 0)
        camRed.append(f.red.isFinite ? f.red : 0)
        camTimes.append(f.tUs.isFinite ? f.tUs : camPacketStartUs)
        guard camGreen.count >= 6 else { return }
        // Carry every frame's REAL PTS (`camTimes`), not just the first, so fps drift
        // / dropped frames don't get flattened onto a synthetic 30 fps grid downstream.
        let pkt = PpgPacket(seq: camSeq, tUs: camPacketStartUs,
                            sampleRateHz: Int(PPGConfig().targetFps),
                            green: camGreen, red: camRed, ir: [], timesUs: camTimes)
        camSeq += 1
        if inCameraWarmup {
            camGreen.removeAll(keepingCapacity: true)
            camRed.removeAll(keepingCapacity: true)
            camTimes.removeAll(keepingCapacity: true)
            return
        }
        let dt = DSPConstants.usPerS / Double(pkt.sampleRateHz)
        for i in 0..<pkt.green.count {
            let t = i < pkt.timesUs.count ? pkt.timesUs[i] : pkt.tUs + (Double(i) * dt).rounded()
            buffers.ppgGreen.push(t, pkt.green[i])
            buffers.ppgRed.push(t, pkt.red[i])
        }
        engine.contactOverride = ppg.uiState == .measuring
        engine.setMotion(motion.movement())
        engine.ingestPpg(pkt)
        if !inCameraWarmup { recorder?.ingestPpg(pkt) }
        camGreen.removeAll(keepingCapacity: true)
        camRed.removeAll(keepingCapacity: true)
        camTimes.removeAll(keepingCapacity: true)
    }

    /// Switch the live source between the camera and the MoniVitals device, and
    /// persist the choice. No-op if already on that source.
    func selectSource(_ kind: MeasurementSource) {
        guard kind != sourceKind || source == nil else { return }
        stopMeasuring()
        updateSettings { $0.measurementSource = kind }
        makeSource(kind)
        // makeSource only settles the new source into `.disconnected`; the Measure
        // screen's `onAppear` normally kicks it live, but an in-place source switch
        // never re-fires that. If the Measure screen is currently up, start the new
        // source now (mirror `connectCamera()`), so the feed isn't left dead until
        // the user leaves and re-enters the Measure tab.
        if measureScreenActive {
            if sourceKind == .camera { startMeasuring() } else { source?.connect() }
        }
    }

    /// The active camera scan style (fingertip contact vs palm hover).
    var scanMode: ScanMode { settings.scanMode }

    /// Switch the camera scan between fingertip and palm, persist the choice, and
    /// re-gate the live pipeline. If a camera measurement is running it restarts so
    /// the presence detector doesn't carry the old mode's hysteresis state.
    func selectScanMode(_ mode: ScanMode) {
        guard mode != settings.scanMode else { return }
        let wasMeasuring = measuring && sourceKind == .camera
        if wasMeasuring { stopMeasuring() }
        updateSettings { $0.scanMode = mode }
        ppg.setScanMode(mode)
        if wasMeasuring { startMeasuring() }
    }

    /// Prepare the active source when its measurement/pairing screen appears.
    /// Camera → open the camera (asks permission). Device → start scanning.
    /// Idempotent.
    func connectCamera() {
        measureScreenActive = true
        // Camera mode: start the calm-UX engine (asks camera permission).
        // Device mode: connect/resume the BLE source.
        if sourceKind == .camera { startMeasuring() } else { source?.connect() }
    }

    /// Release the camera/torch (camera) or stop scanning + streaming (device) when
    /// leaving the Measure screen. Idempotent — safe on every tab switch.
    func leaveMeasure() {
        measureScreenActive = false
        // Close out an in-progress save first so leaving mid-recording doesn't
        // leave the session open while no samples arrive.
        if recording != nil { stopRecording() }
        if sourceKind == .camera {
            stopMeasuring()
            if connectionState != .unsupported {
                connectionState = .disconnected
                stateMessage = nil
            }
            return
        }
        stopMeasuring()
        source?.disconnect()
    }

    /// Disconnect the paired device from the pairing sheet. Same teardown as
    /// leaving Measure in device mode, but the Measure screen may still be up
    /// underneath the sheet, so its visibility tracking is left alone.
    func disconnectDevice() {
        if recording != nil { stopRecording() }
        stopMeasuring()
        source?.disconnect()
    }

    // MARK: - Device pairing (BLE)

    /// Start scanning for nearby MoniVitals devices (from the pairing screen).
    func startDeviceScan() {
        ble?.startScan()
    }

    func stopDeviceScan() {
        ble?.stopScan()
    }

    /// Connect to a device the user tapped in the pairing list.
    func connectDevice(_ device: DiscoveredDevice) {
        ble?.connect(to: device)
    }

    /// Whether SpO₂ is meaningful for the current source (device only).
    var showsSpo2: Bool { sourceKind == .device }

    /// Start streaming from the camera + motion into the live runtime.
    func startMeasuring() {
        if sourceKind == .camera {
            guard !measuring else { return }
            resetRuntime()
            measuring = true
            connectionState = .measuring
            stateMessage = nil
            measureStartedUptime = ProcessInfo.processInfo.systemUptime
            camGreen.removeAll(); camRed.removeAll(); camTimes.removeAll()
            motion.start()
            startTick()
            ppg.start()   // may async-report camera-unavailable → wireCamera → .unsupported
            return
        }
        guard let src = source else { return }
        guard connectionState == .measuring else { return }
        resetRuntime()
        engine.setMotionThresh(settings.motionThresh)
        motion.start()
        src.start()
        startTick()
        measuring = true
        measureStartedUptime = ProcessInfo.processInfo.systemUptime
    }

    func stopMeasuring() {
        if sourceKind == .camera {
            ppg.stop()
            motion.stop()
            stopTick()
            measuring = false
            measureStartedUptime = nil
            camGreen.removeAll(); camRed.removeAll(); camTimes.removeAll()
            // Clear the live readings so the tiles don't keep showing the last value
            // after the user stops.
            liveMetrics = nil; appMetrics = nil
            flushLastVitals()
            return
        }
        source?.stop()
        motion.stop()
        stopTick()
        measuring = false
        measureStartedUptime = nil
        liveMetrics = nil; appMetrics = nil
        flushLastVitals()
    }

    /// Uptime when measuring began, so the first ~1.5 s (torch-on / finger-settle
    /// transient) can be excluded from saved clips + saved metrics.
    private var measureStartedUptime: TimeInterval?
    private let warmupSeconds: TimeInterval = 1.5
    /// True during the settle window right after measuring starts.
    private var inWarmup: Bool {
        guard let t = measureStartedUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - t < warmupSeconds
    }
    /// The warmup transient only exists for the camera (torch strike + finger
    /// settle). The BLE device streams a clean pulse from the first sample, so it
    /// must NOT be gated by the warmup window.
    private var inCameraWarmup: Bool { inWarmup && sourceKind == .camera }

    /// Whether measuring was active when the app last backgrounded, so it can be
    /// resumed on return. The camera + torch stop while suspended.
    private var wasMeasuringBeforeBackground = false

    /// Pause capture while the app is not in the foreground (releases the camera
    /// and turns the torch off).
    func pauseForBackground() {
        // Preserve the resume intent: a full background is usually preceded by an
        // `.inactive` pause that already stopped measuring, so only capture the flag
        // while still measuring — never clobber a `true` with `false`.
        if measuring { wasMeasuringBeforeBackground = true }
        if recording != nil { stopRecording() }
        if measuring { stopMeasuring() }
        source?.stop()
        // Stop the BLE scan too — the app has no bluetooth-central background mode,
        // so a scan left running in the background only drains the battery.
        stopDeviceScan()
        store.flushPending()
        flushLastVitals()
    }

    /// Lighter pause for a transient interruption (`.inactive`: an incoming call,
    /// Control Center / Notification Center pull). Turns the torch off and pauses
    /// capture so the torch doesn't stay lit behind the interruption, but — unlike a
    /// full background — keeps any in-progress recording open, so a brief blip that
    /// returns straight to `.active` resumes the session instead of losing it.
    func pauseForInterruption() {
        guard measuring else { return }
        wasMeasuringBeforeBackground = true
        stopMeasuring()   // turns the torch off + releases capture (camera) / stops the source
        source?.stop()
        flushLastVitals()
    }

    /// Resume when the app returns to the foreground, if it was running.
    func resumeFromBackground() {
        syncOnForeground()
        // If capture was blocked (camera/Bluetooth permission or radio off), re-check
        // on foreground so flipping the toggle in Settings and returning recovers
        // in-app instead of dead-ending on the "unavailable" card. Only while the
        // Measure screen is actually up — never open the camera invisibly from
        // another tab.
        if connectionState == .unsupported, measureScreenActive {
            if sourceKind == .camera { startMeasuring() } else { source?.connect() }
        }
        guard wasMeasuringBeforeBackground, (source != nil || sourceKind == .camera),
              !measuring, measureScreenActive else { return }
        wasMeasuringBeforeBackground = false
        startMeasuring()
    }

    // MARK: - Profiles

    func refreshSubjects() {
        subjects = store.listSubjects()
    }

    func saveSubject(_ s: Subject) {
        store.upsertSubject(s)
        refreshSubjects()
    }

    func selectSubject(_ code: String?) {
        currentSubjectCode = code
    }

    // MARK: - Saving a measurement

    func startRecording(label: SessionLabel, notes: String) {
        guard (source != nil || sourceKind == .camera), let subjectCode = currentSubjectCode else { return }
        if !measuring { startMeasuring() }
        guard liveMetrics?.hrBpm != nil else { return }
        let session = Session(
            id: UUID().uuidString,
            subjectCode: subjectCode,
            label: label,
            startedAt: Self.iso8601.string(from: Date()),
            endedAt: nil,
            notes: notes
        )
        store.createSession(session)
        recorder = Recorder(sessionId: session.id)
        recording = session
        recordingStartedAt = Date()
        recordCounts = [.ppg: 0]
        recordDurationMs = 0
    }

    func stopRecording() {
        guard let session = recording, let rec = recorder else { return }
        rec.flushAll()
        store.endSession(session.id, endedAt: Self.iso8601.string(from: Date()))
        recorder = nil
        recording = nil
        recordingStartedAt = nil
    }

    func addMarker(_ type: AnnotationType, text: String? = nil) {
        guard let session = recording else { return }
        store.addAnnotation(Annotation(id: nil, sessionId: session.id,
                                       tUs: buffers.latestDeviceUs(), type: type,
                                       text: text))
    }

    /// Export a saved measurement to a temp folder; returns its URL for sharing.
    func exportSession(_ sessionId: String) -> URL? {
        try? CSVExport.exportSession(sessionId, store: store)
    }

    // MARK: - Data management

    func deleteSession(_ id: String) {
        store.deleteSession(id)
        // Record the tombstone unconditionally so a delete made while signed OUT
        // still suppresses the remote doc on the next sign-in (no zombie vitals).
        CloudTombstones.add(id, collection: "sessions")
        if let state = authState {
            Task { await SyncService.shared.deleteSessionRemote(id: id, state: state) }
        }
    }

    func deleteSubject(_ code: String) {
        store.deleteSubject(code)
        if currentSubjectCode == code { selectSubject(nil) }
        refreshSubjects()
        CloudTombstones.add(code, collection: "subjects")
        if let state = authState {
            Task { await SyncService.shared.deleteSubjectRemote(code: code, state: state) }
        }
    }

    func deleteAllData() {
        store.deleteAllData()
        subjects = []
        currentSubjectCode = nil
        if let state = authState {
            Task { await SyncService.shared.deleteAllRemote(state: state) }
        }
    }

    // MARK: - Cloud account & sync

    /// Sign in to an existing account. Returns friendly error copy, or nil on success.
    func signIn(email: String, password: String) async -> String? {
        await authenticate { try await AuthService.signIn(email: email, password: password) }
    }

    /// Create a new account. Returns friendly error copy, or nil on success.
    func createAccount(email: String, password: String) async -> String? {
        await authenticate { try await AuthService.signUp(email: email, password: password) }
    }

    /// Continue with Google (OAuth + PKCE). Cancel = silent (nil, stay signed out).
    func signInWithGoogle() async -> String? {
        await federatedSignIn { try await GoogleSignIn().signIn() }
    }

    /// Continue with Apple (native, self-driving). Cancel = silent.
    func signInWithApple() async -> String? {
        await federatedSignIn { try await AppleSignIn().signIn() }
    }

    /// Continue with Apple from a credential the SwiftUI `SignInWithAppleButton`
    /// already collected (`rawNonce` threaded back for Firebase to re-hash).
    func signInWithApple(result: Result<ASAuthorization, Error>, rawNonce: String) async -> String? {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                return AuthService.offlineMessage
            }
            return await federatedSignIn {
                try await AppleSignIn.complete(with: credential, rawNonce: rawNonce)
            }
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return nil
            }
            return AuthService.offlineMessage
        }
    }

    private func authenticate(_ run: () async throws -> AuthState) async -> String? {
        do {
            let state = try await run()
            authState = state
            syncStatus = .idle
            await runSync()
            return nil
        } catch {
            return Self.friendlyMessage(error)
        }
    }

    private func federatedSignIn(_ run: () async throws -> AuthState) async -> String? {
        do {
            let state = try await run()
            authState = state
            syncStatus = .idle
            await runSync()
            return nil
        } catch is GoogleSignIn.Cancelled {
            return nil
        } catch {
            return Self.friendlyMessage(error)
        }
    }

    /// Sign out of the cloud account. Local data stays.
    func signOut() {
        AuthService.clearPersisted()
        SyncService.clearLastSync()
        authState = nil
        lastSyncAt = nil
        syncStatus = .idle
    }

    /// Delete the cloud account: wipe backed-up docs (best effort), delete the
    /// account, then sign out locally. Data on this phone stays.
    func deleteAccount() async -> String? {
        guard let state = authState else { return nil }
        do {
            try await SyncService.shared.deleteAccount(state: state)
            signOut()
            return nil
        } catch let e as CloudError where e == .signedOut {
            signOut()
            return nil
        } catch {
            return Self.friendlyMessage(error)
        }
    }

    /// Manual "Sync now".
    func syncNow() async {
        await runSync()
    }

    /// Foreground sync trigger — skipped if the last sync was under a minute ago.
    private func syncOnForeground() {
        guard authState != nil, syncStatus != .syncing else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < 60 { return }
        Task { await runSync() }
    }

    private func runSync() async {
        guard let state = authState, syncStatus != .syncing else { return }
        syncStatus = .syncing
        do {
            if let outcome = try await SyncService.shared.syncNow(state: state) {
                authState = outcome.state
                lastSyncAt = outcome.syncedAt
                refreshSubjects()
            }
            syncStatus = .idle
        } catch let e as CloudError where e == .signedOut {
            signOut()
            syncStatus = .error(CloudError.signedOut.message)
        } catch {
            syncStatus = .error(Self.friendlyMessage(error))
        }
    }

    private static func friendlyMessage(_ error: Error) -> String {
        (error as? CloudError)?.message ?? AuthService.offlineMessage
    }

    // MARK: - wiring

    private func wire(_ src: DataSource) {
        let ev = src.events

        ev.ppg
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self else { return }
                // Skip the torch-on / finger-settle transient at capture start
                // entirely (camera only): feeding it to the buffers, engine or
                // recorder would poison the DSP windows AND dominate the autoscale,
                // and would show a live reading that isn't saved.
                if self.inCameraWarmup { return }
                let dt = DSPConstants.usPerS / Double(p.sampleRateHz)
                for i in 0..<min(p.green.count, p.red.count) {
                    let t = i < p.timesUs.count ? p.timesUs[i] : p.tUs + (Double(i) * dt).rounded()
                    self.buffers.ppgGreen.push(t, p.green[i])
                    self.buffers.ppgRed.push(t, p.red[i])
                }
                self.engine.setMotion(self.motion.movement())
                self.engine.ingestPpg(p)
                self.recorder?.ingestPpg(p)
            }
            .store(in: &cancellables)

        ev.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self else { return }
                self.contactQuality = s.contactQuality
                self.fps = s.fps
            }
            .store(in: &cancellables)

        ev.connection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, detail in
                guard let self else { return }
                self.connectionState = state
                self.stateMessage = detail?.message
                // Once the source is live, begin streaming into the runtime.
                if state == .measuring {
                    // Re-arm the warmup window on every capture (re)start — a fast
                    // Home↔Measure bounce re-strikes the torch even when `measuring`
                    // was left true, so tying this only to startMeasuring misses it.
                    self.measureStartedUptime = ProcessInfo.processInfo.systemUptime
                    if !self.measuring { self.startMeasuring() }
                } else if state == .disconnected, self.measuring {
                    // Source dropped mid-session (e.g. the device went out of range).
                    // Stop the tick so the Measure screen isn't frozen on a dead feed.
                    self.stopMeasuring()
                }
            }
            .store(in: &cancellables)

        // Device-only feed: HR / SpO₂ / contact reported straight from the hardware.
        ev.deviceMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] m in
                guard let self else { return }
                // Merge partial updates so an HR-only or SpO₂-only notification keeps
                // the last-known value for the field it didn't carry.
                var merged = self.deviceMetrics ?? DeviceMetrics(hrBpm: nil, spo2Pct: nil, contact: false)
                if let hr = m.hrBpm { merged.hrBpm = hr }
                if let s = m.spo2Pct { merged.spo2Pct = s }
                merged.contact = m.contact
                self.deviceMetrics = merged
            }
            .store(in: &cancellables)

        // Pairing-screen feeds (only the BLE source publishes these).
        if let ble = src as? BleSource {
            ble.discovered
                .receive(on: DispatchQueue.main)
                .sink { [weak self] list in self?.discoveredDevices = list }
                .store(in: &cancellables)
            ble.scanning
                .receive(on: DispatchQueue.main)
                .sink { [weak self] on in self?.scanningForDevices = on }
                .store(in: &cancellables)
            // Dropped PPG notifications (sequence gap): clear beat-sensitive DSP
            // state so an RR interval can't silently span the hole. The device's
            // own HR/SpO₂ keep showing; DSP-derived RR/HRV re-settle honestly.
            ble.streamGap
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.engine.reset() }
                .store(in: &cancellables)
        }
    }

    private func teardownSource() {
        // Flush + close any in-progress recording so switching source (or dropping
        // it) doesn't orphan the open session and lose the buffered samples.
        if recording != nil { stopRecording() }
        // Always stop + fully reset the camera PPGEngine on teardown — its `stop()`
        // runs `resetInternal()`, clearing the streaming band-pass / beat detector /
        // clean-IBI history / ring buffers / lastTUs. This must fire on EVERY source
        // switch (including device→camera, where `sourceKind` is still `.device`
        // here), so no stale 30 fps filter/beat state can carry into a 100 sps device
        // stream or vice-versa. `stop()` is idempotent and safe even if never started.
        ppg.stop(); ppg.onFrame = nil
        engine.isBleSource = false
        stopTick()
        cancellables.removeAll()
        source?.disconnect()
        source = nil
        camGreen.removeAll(); camRed.removeAll(); camTimes.removeAll()
        discoveredDevices = []
        scanningForDevices = false
        deviceMetrics = nil
        // Drop the previous source's live signal-quality readout too, so a
        // device→camera→device switch can't leave the Signal-quality card showing
        // the old session's value for one tick until fresh `liveMetrics` land.
        contactQuality = 0
        fps = 0
    }

    func resetRuntime() {
        buffers.clear()
        engine.reset()
        hrTrend = []
        respTrend = []
        // Drop the last tick's readings so a source switch / fresh start can't show
        // the previous source's (or a stale) number until the next tick lands.
        liveMetrics = nil
        appMetrics = nil
    }

    private func startTick() {
        stopTick()
        let timer = Timer(timeInterval: AppModel.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        let latest = buffers.latestDeviceUs()
        if sourceKind == .camera {
            // Camera mode: gated HR from PPGEngine, plus richer rolling estimates
            // from the shared MetricsEngine fed by the same real camera samples.
            let q = Int((ppg.windowQuality(seconds: 3) * 100).rounded())
            let dsp = engine.snapshot(latest)
            let app = MetricsSnapshot(
                tUs: latest,
                hrBpm: ppg.bpm ?? dsp.hrBpm,
                respRateBpm: dsp.respRateBpm,
                rmssdMs: ppg.hrvRmssd ?? dsp.rmssdMs,
                sdnnMs: dsp.sdnnMs,
                signalQuality: max(q, dsp.signalQuality),
                motion: motion.movement(),
                contact: ppg.uiState == .measuring,
                spo2Pct: nil)
            appMetrics = app
            liveMetrics = app
            persistLastVitals(app)
            Self.pushTrend(app.hrBpm, into: &hrTrend)
            Self.pushTrend(app.respRateBpm, into: &respTrend)
            if let rec = recorder, let start = recordingStartedAt, !inCameraWarmup {
                recordCounts = rec.counts
                recordDurationMs = Date().timeIntervalSince(start) * 1000
                store.addMetrics(MetricsRecord(
                    id: nil, sessionId: rec.sessionId, tUs: app.tUs,
                    hrBpm: app.hrBpm, respRateBpm: app.respRateBpm,
                    rmssdMs: app.rmssdMs, sdnnMs: app.sdnnMs,
                    signalQuality: app.signalQuality, motion: app.motion, spo2Pct: nil))
            }
            return
        }
        engine.setMotion(motion.movement())
        // In device mode the hardware reports contact; drive the DSP gate off it so
        // HR/RR/HRV aren't blanked by the camera-tuned brightness classifier.
        if sourceKind == .device {
            // Assume contact while the device is streaming — the auxiliary contact
            // notify can lag the PPG, and `false` would blank RR/HRV needlessly.
            engine.contactOverride = deviceMetrics?.contact ?? true
        }
        var app = engine.infer(at: latest)

        // On the MoniVitals device the hardware reports HR / SpO₂ / contact itself;
        // trust those over the DSP estimate (RR + HRV still come from the streamed
        // pulse via the DSP). The camera source leaves SpO₂ nil.
        if sourceKind == .device, let dm = deviceMetrics {
            if let hr = dm.hrBpm { app.hrBpm = hr }
            app.spo2Pct = dm.spo2Pct
            app.contact = dm.contact
        }

        appMetrics = app
        liveMetrics = app
        persistLastVitals(app)
        Self.pushTrend(app.hrBpm, into: &hrTrend)
        Self.pushTrend(app.respRateBpm, into: &respTrend)
        if let rec = recorder, let start = recordingStartedAt, !inCameraWarmup {
            recordCounts = rec.counts
            recordDurationMs = Date().timeIntervalSince(start) * 1000
            store.addMetrics(MetricsRecord(
                id: nil, sessionId: rec.sessionId, tUs: app.tUs,
                hrBpm: app.hrBpm, respRateBpm: app.respRateBpm,
                rmssdMs: app.rmssdMs, sdnnMs: app.sdnnMs,
                signalQuality: app.signalQuality, motion: app.motion,
                spo2Pct: app.spo2Pct
            ))
        }
    }

    /// Append a finite metric value to a fixed-length rolling trend array.
    private static func pushTrend(_ v: Double?, into arr: inout [Double]) {
        guard let v, v.isFinite else { return }
        arr.append(v)
        if arr.count > trendLength { arr.removeFirst(arr.count - trendLength) }
    }

    // MARK: - Last-vitals persistence (throttled)

    /// One shared ISO-8601 formatter — allocating a fresh `ISO8601DateFormatter`
    /// per timestamp is surprisingly costly, and we stamp times every save/tick.
    private static let iso8601 = ISO8601DateFormatter()

    /// UserDefaults writes are throttled to ~2 s; the in-memory snapshot still
    /// updates every tick. `flushLastVitals()` runs on stop/background.
    private static let lastVitalsWriteInterval: TimeInterval = 2
    private var lastVitalsWrittenAt: Date = .distantPast
    private var lastVitalsNeedsWrite = false

    private func persistLastVitals(_ m: MetricsSnapshot) {
        guard m.hrBpm != nil || m.respRateBpm != nil || m.rmssdMs != nil || m.sdnnMs != nil || m.spo2Pct != nil else {
            return
        }
        let snapshot = LastVitalsSnapshot(
            capturedAt: Self.iso8601.string(from: Date()),
            source: sourceKind,
            hrBpm: m.hrBpm,
            respRateBpm: m.respRateBpm,
            rmssdMs: m.rmssdMs,
            sdnnMs: m.sdnnMs,
            signalQuality: m.signalQuality,
            motion: m.motion,
            spo2Pct: m.spo2Pct
        ).sanitizedForDefaultDisplay
        lastVitals = snapshot
        lastVitalsNeedsWrite = true
        if Date().timeIntervalSince(lastVitalsWrittenAt) >= Self.lastVitalsWriteInterval {
            flushLastVitals()
        }
    }

    /// Write the pending last-vitals snapshot to UserDefaults, if any.
    private func flushLastVitals() {
        guard lastVitalsNeedsWrite, let snapshot = lastVitals else { return }
        // Encrypted at rest (Keychain) rather than plaintext UserDefaults — this is PHI.
        KeychainStore.save(snapshot, account: lastVitalsKey)
        lastVitalsWrittenAt = Date()
        lastVitalsNeedsWrite = false
    }
}
