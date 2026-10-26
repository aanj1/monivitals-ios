//
//  PPGEngine.swift
//  MoniVitals — PPGCore
//
//  Orchestrator. Owns capture → filtering → quality → finger detection → history →
//  reconstruction → crossfade → state machine, and maintains the TWO streams:
//   • measuredPPG — only real camera-derived samples (+ quality). Never reconstructed.
//   • displayPPG  — visually continuous; may be interpolated / reconstructed / crossfaded.
//  The production UI reads only `uiState` (3 calm states) and `displaySamples`.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class PPGEngine: ObservableObject {

    // MARK: production-facing published state
    @Published private(set) var uiState: PPGUIState = .measuring
    @Published private(set) var displaySamples: [PPGSample] = []
    @Published private(set) var bpm: Double?
    /// Debug snapshot — only meaningful when PPGConfig.debugEnabled.
    @Published private(set) var debug: PPGDebugSnapshot = .empty
    @Published private(set) var cameraUnavailableMessage: String?

    // MARK: Cardiographer-style scope signals
    /// Good / Fair / Poor band for the on-scope pill.
    @Published private(set) var qualityBand: PPGQualityBand = .poor
    /// Latest raw red ROI mean, for the "red NNN" readout.
    @Published private(set) var redLevel: Int = 0
    /// Small live ROI thumbnail for the scope corner.
    @Published private(set) var previewImage: CGImage?
    /// Coaching line derived from state + band (e.g. "Weak/noisy — press gently…").
    @Published private(set) var coaching: String = ""
    /// Torch on/off, for the Flash control.
    @Published private(set) var torchOn = true
    /// HRV (RMSSD, ms) from clean beats — WELLNESS. Nil until enough clean intervals
    /// on a good signal; gated exactly like `bpm` so it's never a garbage number.
    @Published private(set) var hrvRmssd: Double?
    /// Wellness stress / recovery band from RMSSD. Nil until HRV is available.
    @Published private(set) var stressBand: PPGStressBand?

    /// Raw per-frame passthrough (the real ROI sample) for a recording bridge.
    /// Always the real signal — never reconstructed. Called on MAIN.
    var onFrame: ((PPGFrame) -> Void)?

    // MARK: config + components
    private var cfg: PPGConfig
    private let capture: PPGCaptureController
    private let motion = PPGMotionProvider()
    private let quality: PPGQualityEstimator
    private var finger: PPGFingerDetector
    private let history = PPGHistory()
    private let reconstructor: PPGReconstructor
    private let crossfade: PPGCrossfade
    private let machine: PPGStateMachine
    private let bandpass: PPGBiquad
    private let baseline = PPGBaselineTracker()
    private let beats = PPGBeatDetector()

    // MARK: histories
    private let greenHistory: PPGRingBuffer      // raw green, for AC/DC + intensity
    private let filteredHistory: PPGRingBuffer   // band-passed, for periodicity
    private var measuredPPG: [PPGSample] = []    // real only
    private var dts: [Double] = []               // recent inter-frame µs
    private var beatSegment: [Double] = []       // filtered samples since last beat
    private var recentBpm: [Double] = []
    private var cleanIbis: [Double] = []          // clean inter-beat intervals (ms), for HRV
    private var cleanIbiTimesUs: [Double] = []    // beat time of each clean IBI, for time-pruning

    private var lastTUs: Double?
    private var lastRealValue = 0.0
    private var lastDisplayValue = 0.0
    private var fs: Double

    private let maxDisplay = 180                  // ~6 s at 30 fps
    private let maxMeasured = 600                 // ~20 s

    init(config: PPGConfig = PPGConfig()) {
        cfg = config
        fs = config.targetFps
        capture = PPGCaptureController(config: config)
        quality = PPGQualityEstimator(config: config)
        finger = PPGFingerDetector(config: config)
        reconstructor = PPGReconstructor(config: config)
        crossfade = PPGCrossfade(config: config)
        machine = PPGStateMachine(config: config)
        bandpass = PPGBiquad(lowHz: config.pulseLowHz, highHz: config.pulseHighHz, fs: config.targetFps)
        greenHistory = PPGRingBuffer(capacity: Int(config.targetFps * 10))
        filteredHistory = PPGRingBuffer(capacity: Int(config.targetFps * 10))

        capture.onFrame = { [weak self] frame in self?.handle(frame) }
        capture.onNoCamera = { [weak self] msg in self?.cameraUnavailableMessage = msg }
        capture.onPreview = { [weak self] cg in self?.previewImage = cg }
    }

    // MARK: lifecycle

    func start() {
        resetInternal()
        motion.start()
        capture.start()
    }

    /// Switch between fingertip and palm presence gating. Rebuilds the presence
    /// detector (its thresholds are baked in at init) and retargets the capture
    /// exposure gate. Safe mid-capture; the caller decides whether to restart.
    func setScanMode(_ mode: ScanMode) {
        guard cfg.scanMode != mode else { return }
        cfg.scanMode = mode
        capture.setScanMode(mode)
        finger = PPGFingerDetector(config: cfg)
        coaching = Self.coachingText(uiState, qualityBand, mode: mode)
    }

    func stop() {
        capture.stop()
        motion.stop()
        resetInternal()
    }

    /// Real (non-reconstructed) samples within the last `seconds`, for inference.
    func measuredWindow(seconds: Double) -> [PPGSample] {
        guard let last = measuredPPG.last?.tUs else { return [] }
        let cutoff = last - seconds * cfg.usPerS
        return measuredPPG.filter { !$0.isReconstructed && $0.tUs >= cutoff }
    }

    /// Minimum quality across the measured window (for inference gating).
    func windowQuality(seconds: Double) -> Double {
        let w = measuredWindow(seconds: seconds)
        return w.map { $0.quality }.min() ?? 0
    }

    // MARK: per-frame pipeline (MAIN)

    private func handle(_ f: PPGFrame) {
        let t = f.tUs
        let dtUs = lastTUs.map { t - $0 } ?? (cfg.usPerS / fs)
        // Non-monotonic timestamp: drop the frame WITHOUT advancing the clock, so
        // one bad stamp can't also poison the next frame's dt.
        guard dtUs > 0 else { return }

        // Dropped-frame gap: a large jump (e.g. dt = 100 ms) fed to the streaming
        // band-pass / beat detector as one adjacent step fakes a fast transient →
        // a phantom peak → a bogus IBI/HRV spanning the gap. On a gap, keep the DC /
        // finger / motion / history state fresh but RESYNC the beat pipeline and emit
        // NO beat this frame, so nothing straddles the discontinuity.
        let nominalDtUs = cfg.usPerS / fs
        if lastTUs != nil, dtUs > 1.8 * nominalDtUs {
            lastTUs = t
            // Keep presence / motion / DC current so the state machine doesn't stall.
            let filtered = bandpass.process(f.green)   // re-prime the filter with this sample
            _ = baseline.update(f.green)
            greenHistory.push(t, f.green)
            filteredHistory.push(t, filtered)
            finger.update(red: f.red, satFraction: f.satFraction, tUs: t)
            onFrame?(f)
            // Re-sync the beat pipeline across the gap: clear the streaming filter's
            // memory, drop the partial beat segment, and reset the detector's local
            // peak shape (keeping its last-peak anchor for the refractory window).
            bandpass.reset()
            beatSegment.removeAll(keepingCapacity: true)
            beats.resyncAcrossGap()
            lastRealValue = filtered
            return
        }

        lastTUs = t
        dts.append(dtUs); if dts.count > 30 { dts.removeFirst(dts.count - 30) }
        let dtS = dtUs / cfg.usPerS

        // Bridge the raw (always-real) frame to any recorder. Reconstructed display
        // samples are never routed here.
        onFrame?(f)

        // Real signal: band-pass the green channel; track its baseline.
        let filtered = bandpass.process(f.green)
        _ = baseline.update(f.green)
        greenHistory.push(t, f.green)
        filteredHistory.push(t, filtered)

        // Finger + motion + quality (all internal).
        finger.update(red: f.red, satFraction: f.satFraction, tUs: t)
        let motionLevel = motion.level
        let gWin = greenHistory.tail(Int(fs * 4))
        let fWin = filteredHistory.tail(Int(fs * 4))
        let q = quality.score(filtered: fWin, green: gWin, dts: dts,
                              satFraction: f.satFraction, motionLevel: motionLevel,
                              fingerProb: finger.probability, fs: fs)

        // Beat detection → rate + clean-beat history (good quality only).
        beatSegment.append(filtered)
        if beats.process(filtered, tUs: t) != nil {
            if q.composite >= cfg.qualityGoodEnter {
                history.addCleanBeat(ibiMs: beats.lastIbiMs, beatSamples: beatSegment,
                                     baseline: baseline.current ?? 0)
            }
            // Feed BOTH the rate and HRV from GOOD-quality beats only, so a noisy /
            // "fair" signal can't surface a wrong BPM (the display gate isn't enough).
            if let ibi = beats.lastIbiMs, Self.isStableIbi(ibi, recent: cleanIbis),
               q.composite >= cfg.qualityGoodEnter {
                recentBpm.append(60_000.0 / ibi)
                if recentBpm.count > 7 { recentBpm.removeFirst(recentBpm.count - 7) }
                cleanIbis.append(ibi)
                cleanIbiTimesUs.append(t)
                // Time-prune to the last ~60 s: HRV must describe recent beats, not
                // intervals from minutes ago glued together across dropouts.
                while let first = cleanIbiTimesUs.first, t - first > 60.0 * cfg.usPerS {
                    cleanIbiTimesUs.removeFirst()
                    cleanIbis.removeFirst()
                }
            }
            beatSegment.removeAll(keepingCapacity: true)
        }
        if beatSegment.count > Int(fs * 2) { beatSegment.removeFirst(beatSegment.count - Int(fs * 2)) }

        // Advance the internal state machine (hysteresis inside).
        let reconElapsed = reconstructor.elapsed(t)
        let state = machine.update(PPGStateInputs(
            quality: q.composite, fingerPresent: finger.isPresent,
            removedEvidence: finger.removedEvidence, reconElapsed: reconElapsed, tUs: t))

        // React to the state for the reconstruction / crossfade lifecycle.
        switch state {
        case .reconstructing:
            if !reconstructor.isActive {
                // Anchor to the last DISPLAYED value (what the user sees) so there's no
                // visible step — whether a fresh gap or a recovering→reconstructing bounce.
                reconstructor.begin(at: t, lastValue: lastDisplayValue, history: history)
            }
        case .recovering:
            if reconstructor.isActive, !crossfade.isActive {
                crossfade.begin(at: t, reconTail: lastDisplayValue, realHead: filtered)
            }
        default:
            reconstructor.end()
            crossfade.reset()
        }

        // Produce the DISPLAY sample.
        var displayValue = filtered
        var reconstructed = false
        switch state {
        case .reconstructing:
            displayValue = reconstructor.next(tUs: t, dtS: dtS, history: history)
            reconstructed = true
        case .recovering:
            let rv = reconstructor.next(tUs: t, dtS: dtS, history: history)
            displayValue = crossfade.value(at: t, reconValue: rv, realValue: filtered)
            reconstructed = crossfade.isActive
            if !crossfade.isActive { reconstructor.end() }
        default:
            displayValue = filtered
            reconstructed = false
        }

        lastRealValue = filtered
        lastDisplayValue = displayValue

        // measuredPPG is the REAL, trustworthy stream for inference — populate it ONLY
        // when the signal is genuinely usable. During a dropout (reconstructing / lost /
        // noFinger) the raw `filtered` value is garbage, so it must not accrue here.
        let measuredUsable = (state == .good || state == .degraded || state == .recovering)
            && q.composite >= cfg.qualityUsable
        if measuredUsable {
            appendMeasured(PPGSample(tUs: t, value: filtered, isReconstructed: false, quality: q.composite))
        }
        appendDisplay(PPGSample(tUs: t, value: displayValue, isReconstructed: reconstructed, quality: q.composite))

        // Publish calm UI state + the Cardiographer-style scope signals.
        uiState = state.uiState
        redLevel = Int(f.red.rounded())
        let band: PPGQualityBand = q.composite >= cfg.qualityGoodEnter ? .good
            : (q.composite >= cfg.qualityUsable ? .fair : .poor)
        qualityBand = band
        if state == .noFinger {
            // Clear ALL beat state, including the detector itself and the partial
            // beat segment — stale peak times / half-beats must not seed the next
            // acquisition.
            recentBpm.removeAll(); cleanIbis.removeAll(); cleanIbiTimesUs.removeAll()
            history.reset(); beats.reset(); beatSegment.removeAll(keepingCapacity: true)
        }
        // Accuracy gate: never show a number on a poor / unsettled signal.
        let enoughBeats = recentBpm.count >= 3
        bpm = (band != .poor && enoughBeats) ? recentBpm.sorted()[recentBpm.count / 2] : nil
        // HRV (wellness) — gated exactly like bpm; needs several clean intervals.
        if band != .poor, cleanIbis.count >= 12, let hrv = HeartRateVariability.compute(rrMs: cleanIbis) {
            hrvRmssd = hrv.rmssdMs
            stressBand = Self.stressBand(for: hrv.rmssdMs)
        } else {
            hrvRmssd = nil
            stressBand = nil
        }
        coaching = Self.coachingText(state.uiState, band, mode: cfg.scanMode)

        if PPGConfig.debugEnabled {
            debug = PPGDebugSnapshot(
                internalState: state, uiState: state.uiState, quality: q,
                fingerProbability: finger.probability, fingerPresent: finger.isPresent,
                reconstructing: reconstructor.isActive, reconElapsed: reconElapsed,
                crossfading: crossfade.isActive, bpm: bpm, measuredFs: fs)
        }
    }

    #if DEBUG
    /// Test-only: drive one synthetic frame through the real pipeline (there is no
    /// camera in the test host, so tests can't reach `handle` any other way).
    func testFeed(_ f: PPGFrame) { handle(f) }
    #endif

    private func appendMeasured(_ s: PPGSample) {
        measuredPPG.append(s)
        if measuredPPG.count > maxMeasured { measuredPPG.removeFirst(measuredPPG.count - maxMeasured) }
    }

    private func appendDisplay(_ s: PPGSample) {
        displaySamples.append(s)
        if displaySamples.count > maxDisplay { displaySamples.removeFirst(displaySamples.count - maxDisplay) }
    }

    private func resetInternal() {
        quality.reset(); finger.reset(); history.reset(); reconstructor.reset()
        crossfade.reset(); machine.reset(); bandpass.reset(); baseline.reset(); beats.reset()
        greenHistory.clear(); filteredHistory.clear()
        measuredPPG.removeAll(); displaySamples.removeAll(); dts.removeAll()
        beatSegment.removeAll(); recentBpm.removeAll()
        lastTUs = nil; lastRealValue = 0; lastDisplayValue = 0
        bpm = nil; uiState = .measuring; debug = .empty; cameraUnavailableMessage = nil
        qualityBand = .poor; redLevel = 0; previewImage = nil; coaching = ""; torchOn = true
        cleanIbis.removeAll(); cleanIbiTimesUs.removeAll(); hrvRmssd = nil; stressBand = nil
    }

    // MARK: - Controls (Cardiographer parity)

    /// Flash button: toggle the torch.
    func toggleTorch() {
        capture.toggleTorch()
        torchOn.toggle()
    }

    /// Recalibrate button: hand the camera back to auto so it re-settles + re-locks a
    /// fresh exposure, and clear all DSP / reconstruction / beat state for a clean
    /// re-acquire (a bad lock or drift can be recovered without leaving the screen).
    func recalibrate() {
        capture.recalibrate()
        resetInternal()
    }

    private static func coachingText(_ ui: PPGUIState, _ band: PPGQualityBand,
                                     mode: ScanMode) -> String {
        switch ui {
        case .fingerRemoved:
            return mode == .palm
                ? "Hold your palm a few centimetres over the rear camera."
                : "Rest a fingertip over the rear camera."
        case .adjustFinger:
            return mode == .palm
                ? "Steady your palm and hold still."
                : "Adjust your finger and hold still."
        case .measuring:
            switch band {
            case .good: return "Measuring — hold steady."
            case .fair: return "Keep still — settling…"
            case .poor:
                return mode == .palm
                    ? "Weak/noisy — bring your palm a little closer and keep still."
                    : "Weak/noisy — press gently and keep still."
            }
        }
    }

    /// Reject one-off false peaks / missed peaks before they move BPM or HRV.
    /// Keep startup permissive until a local cadence exists.
    private static func isStableIbi(_ ibiMs: Double, recent: [Double]) -> Bool {
        guard ibiMs.isFinite, ibiMs >= 285, ibiMs <= 1500 else { return false }
        guard recent.count >= 4 else { return true }
        let med = median(recent.suffix(8).map { $0 })
        guard med > 0 else { return true }
        let ratio = ibiMs / med
        return ratio >= 0.72 && ratio <= 1.38
    }

    /// Wellness stress/recovery band from RMSSD (ms). Soft, personal thresholds.
    private static func stressBand(for rmssd: Double) -> PPGStressBand {
        if rmssd >= 50 { return .calm }
        if rmssd >= 25 { return .balanced }
        return .tense
    }
}
