//
//  MetricsEngine.swift
//  MoniVitals
//
//  Ties the pulse detectors together into a live engine. It ingests camera pulse
//  packets (with monotonic timestamps) plus a movement level, and produces a
//  snapshot of the four readings the app shows: heart rate, respiratory rate,
//  HRV, and signal quality (with movement).
//

import Foundation

/// App-computed readings at a point in time.
struct MetricsSnapshot {
    var tUs: Double
    /// Beats per minute, or nil until enough clean pulse has been seen.
    var hrBpm: Double?
    /// Breaths per minute, or nil until enough slow modulation is visible.
    var respRateBpm: Double?
    /// HRV — root mean square of successive differences (ms), or nil.
    var rmssdMs: Double?
    /// HRV — standard deviation of intervals (ms), or nil.
    var sdnnMs: Double?
    /// 0…100 signal quality (fingertip contact + clean pulse).
    var signalQuality: Int
    /// 0…100 movement level.
    var motion: Int
    /// True when a fingertip appears to be covering the camera.
    var contact: Bool
    /// Blood-oxygen % — only reported by the MoniVitals hardware device (the phone
    /// camera can't estimate SpO₂), so it stays nil on the camera source.
    var spo2Pct: Double? = nil
}

final class MetricsEngine {
    // Detectors / reporters.
    var foot: PpgFootDetector?
    private let hrReporter = PulseHeartRateReporter()
    private let hrvReporter = HeartRateVariabilityReporter()
    private var quality: SignalQualityReporter?

    // Rolling raw pulse used for the window-based HR / respiratory estimates.
    private var greenWindow: [Double] = []
    private var greenWindowT: [Double] = []

    var ppgFs = 0
    var motionThresh: Double = DSPConstants.motionThresh
    /// Latest movement level, pushed in from the MotionMonitor.
    var motionLevel = 0
    /// Overrides the camera contact gate when set. BLE device mode streams a pulse
    /// whose brightness/perfusion don't match the camera-tuned classifier, so the
    /// app injects the device's own streaming/contact flag here.
    var contactOverride: Bool? = nil
    /// True when the pulse comes from the BLE hardware device. The signal-quality
    /// classifier is camera-tuned, so only this flag (not a mere contact override)
    /// bypasses the clean-signal gate on fresh estimates.
    var isBleSource: Bool = false
    /// Whether HRV is gated on phone stillness. Only meaningful for the camera
    /// source — a paired finger sensor isn't affected by how still the phone is.
    var motionGatesHrv = true

    /// Contact hysteresis: hold the last readings through a brief contact dip so a
    /// momentary loss doesn't wipe the numbers on screen. Only after a sustained
    /// loss do we reset the reporters and blank the readings.
    private var noContactTicks = 0
    private let contactGraceTicks = 8   // ~2 s at the 0.25 s tick
    private var lastResp: Double?
    private var lastRmssd: Double?
    private var lastSdnn: Double?
    /// Recent breathing estimates; the shown value is their median so one odd
    /// window can't jerk the number around.
    private var respRecent: [Double] = []
    /// Ticks since the last fresh HRV compute. Held values are blanked after this
    /// runs out so a bad early number can't stay pinned on screen for minutes.
    private var hrvStaleTicks = 0
    private let hrvStaleLimit = 40      // ~10 s at the 0.25 s tick
    /// Same staleness idea for the held HR and breathing numbers: ticks since the
    /// last successful fresh estimate; blank the held value when it runs out.
    private var hrStaleTicks = 0
    private var respStaleTicks = 0
    private let vitalsStaleLimit = 40   // ~10 s at the 0.25 s tick
    /// Recent detected pulse beat times (µs) for waveform markers.
    private(set) var recentFeet: [Double] = []

    /// How many seconds of pulse to keep for the rolling estimates.
    private let hrWindowS = 8.0
    private let respWindowS = 16.0

    func setMotionThresh(_ thresh: Double) { motionThresh = thresh }

    func setMotion(_ level: Int) { motionLevel = level }

    func ingestPpg(_ p: PpgPacket) {
        if foot == nil || ppgFs != p.sampleRateHz {
            foot = PpgFootDetector(fs: Double(p.sampleRateHz))
            quality = SignalQualityReporter(fs: Double(p.sampleRateHz))
            ppgFs = p.sampleRateHz
        }
        let dt = DSPConstants.usPerS / Double(p.sampleRateHz)
        // Only trust the real per-sample times when they cover every green sample.
        // A partially filled `timesUs` (non-empty but shorter than green) would mix
        // real and synthetic times mid-buffer and can go non-monotonic; in that case
        // fall back to the synthetic grid for ALL samples. The common cases — full
        // (camera) and empty (BLE) — are unchanged.
        let useReal = p.timesUs.count == p.green.count
        for i in 0..<min(p.green.count, p.red.count) {
            // Prefer the REAL per-sample time when the camera bridge supplies it, so
            // beat timing (and HR) tracks actual fps rather than a synthetic 30 fps
            // grid; the BLE path leaves `timesUs` empty and falls back to the formula.
            let t = useReal ? p.timesUs[i] : p.tUs + (Double(i) * dt).rounded()
            let g = p.green[i]
            let r = p.red[i]
            greenWindow.append(g)
            greenWindowT.append(t)
            quality?.push(red: r, green: g)
            if let f = foot?.process(g, t) {
                // Gate HRV on the CURRENT signal, evaluated at the moment the beat
                // lands, rather than a flag left over from the last ~4 Hz snapshot
                // (which drops the first clean beats of a session and can leak a
                // dirty beat across a quality transition). Beats are rare (~1–2 Hz)
                // so this extra non-mutating peek is cheap. All feet still mark the
                // waveform; only clean beats feed HRV.
                if beatCleanForHrvNow() { hrvReporter.addBeat(f) }
                pushCapped(&recentFeet, f)
            }
        }
        trimWindows()
    }

    /// Produce a snapshot at the given timestamp.
    func snapshot(_ tUs: Double) -> MetricsSnapshot {
        // Effective sample rate from the ACTUAL recorded sample times (median
        // inter-sample dt) so real fps drift / drops scale the window correctly;
        // fall back to the nominal rate when times aren't informative.
        let fs = effectiveFs()
        let q = quality?.score() ?? SignalQualityScore(quality: 0, contact: false)

        // Heart rate + breathing only need a fingertip on the lens — the rolling
        // median tolerates the mild jitter of holding the phone. HRV is far more
        // motion-sensitive (a jostled beat corrupts the interval), so it also
        // requires the hand to be fairly still.
        let hasContact = contactOverride ?? q.contact
        let stillEnough = !motionGatesHrv || motionLevel <= Int(motionThresh)
        // Fresh estimates additionally require a decent signal — computing on a
        // noisy window surfaces false beats (HR spikes, giant HRV). The quality
        // classifier is camera-tuned, so only the BLE device source skips this
        // gate (a contact override alone must NOT bypass it).
        let cleanEnough = isBleSource || q.quality >= DSPConstants.minQualityForVitals

        var hr: Double? = nil
        var resp: Double? = nil
        var rmssd: Double? = nil
        var sdnn: Double? = nil
        var contactForUI = hasContact

        if hasContact {
            // DECAY the miss counter rather than zeroing it: a lone good tick amid
            // real flicker shouldn't reset the grace window (that would hold a stale
            // reading forever and push half-off garbage into the median). Only when
            // the counter has fully drained (solid contact) do we compute + push a
            // fresh estimate; while still recovering we hold the last values.
            noContactTicks = max(0, noContactTicks - 1)
            if noContactTicks == 0, cleanEnough {
                let hrWin = tailWindow(seconds: hrWindowS)
                let hrEstimate = PpgHeartRate.estimate(hrWin, fs: fs)
                if hrEstimate != nil { hrStaleTicks = 0 } else { hrStaleTicks += 1 }
                hr = hrReporter.push(hrEstimate)

                let respWin = tailWindow(seconds: respWindowS)
                if let r = RespiratoryRate.estimate(respWin, fs: fs) {
                    respStaleTicks = 0
                    respRecent.append(r)
                    if respRecent.count > 3 { respRecent.removeFirst(respRecent.count - 3) }
                    let smoothed = median(respRecent)
                    resp = smoothed
                    lastResp = smoothed
                } else {
                    respStaleTicks += 1
                    resp = lastResp
                }

                if stillEnough, let hrv = hrvReporter.result() {
                    rmssd = hrv.rmssdMs
                    sdnn = hrv.sdnnMs
                    lastRmssd = rmssd
                    lastSdnn = sdnn
                    hrvStaleTicks = 0
                } else {
                    // Hold HRV through a brief motion spike rather than blanking it.
                    hrvStaleTicks += 1
                    rmssd = lastRmssd
                    sdnn = lastSdnn
                }
            } else {
                // Recovering from a dip, or the signal is too noisy for a fresh
                // estimate — hold last values without pushing new data.
                hrvStaleTicks += 1
                hrStaleTicks += 1
                respStaleTicks += 1
                hr = hrReporter.value()
                resp = lastResp
                rmssd = lastRmssd
                sdnn = lastSdnn
                contactForUI = hr != nil
            }
            if hrvStaleTicks >= hrvStaleLimit {
                // No fresh clean HRV for a while — blank it rather than keep an
                // increasingly stale (possibly wrong) number pinned on screen.
                lastRmssd = nil
                lastSdnn = nil
                rmssd = nil
                sdnn = nil
            }
            // Same for held HR and breathing: no successful fresh estimate for a
            // while means the held number no longer describes the finger on the
            // lens — blank it rather than keep it pinned.
            if hrStaleTicks >= vitalsStaleLimit {
                hrReporter.reset()
                hr = nil
            }
            if respStaleTicks >= vitalsStaleLimit {
                lastResp = nil
                respRecent.removeAll()
                resp = nil
            }
        } else {
            noContactTicks += 1
            if noContactTicks >= contactGraceTicks {
                // Sustained loss — clear everything so no stale reading lingers, and
                // zero the counter so contact returning recovers promptly. The HRV
                // beat window and breathing median go too: values straddling the
                // gap would contaminate the first estimates after recovery.
                hrReporter.reset()
                hrvReporter.reset()
                lastResp = nil
                lastRmssd = nil
                lastSdnn = nil
                respRecent.removeAll()
                noContactTicks = 0
                hrStaleTicks = 0
                respStaleTicks = 0
                hrvStaleTicks = 0
            } else {
                // Brief dip — hold the last readings so the numbers don't flicker
                // in and out over a momentary loss of contact.
                hr = hrReporter.value()
                resp = lastResp
                rmssd = lastRmssd
                sdnn = lastSdnn
                contactForUI = hr != nil
            }
        }

        return MetricsSnapshot(
            tUs: tUs,
            hrBpm: hr,
            respRateBpm: resp,
            rmssdMs: rmssd,
            sdnnMs: sdnn,
            signalQuality: q.quality,
            motion: motionLevel,
            contact: contactForUI
        )
    }

    func reset() {
        foot = nil
        quality = nil
        ppgFs = 0
        greenWindow.removeAll()
        greenWindowT.removeAll()
        recentFeet.removeAll()
        hrReporter.reset()
        hrvReporter.reset()
        motionLevel = 0
        contactOverride = nil
        // NOTE: isBleSource is deliberately NOT cleared here. Its single source of
        // truth is makeSource (set once when the source is created/switched), so it
        // must survive the resets that fire mid-session (startMeasuring's device
        // branch and the BLE streamGap handler). Clearing it here silently regated
        // device DSP through the camera-tuned quality classifier for the rest of
        // the session. The camera path sets it false in makeSource, so it stays false.
        noContactTicks = 0
        lastResp = nil
        lastRmssd = nil
        lastSdnn = nil
        respRecent.removeAll()
        hrvStaleTicks = 0
        hrStaleTicks = 0
        respStaleTicks = 0
    }

    // MARK: - internals

    /// Whether a beat detected right now should feed HRV, evaluated against the
    /// CURRENT signal. Mirrors the clean-signal gate used in `snapshot()` exactly
    /// (`hasContact && cleanEnough`) but reads a non-mutating `peek()` so it can
    /// run on the high-rate ingest path without disturbing the snapshot EWMA or
    /// waiting for the next ~4 Hz snapshot to refresh a cached flag.
    private func beatCleanForHrvNow() -> Bool {
        let q = quality?.peek() ?? SignalQualityScore(quality: 0, contact: false)
        let hasContact = contactOverride ?? q.contact
        let cleanEnough = isBleSource || q.quality >= DSPConstants.minQualityForVitals
        return hasContact && cleanEnough
    }

    /// Sample rate implied by the ACTUAL recorded sample times over the HR window:
    /// median inter-sample dt → fs = 1e6 / medianDt. Falls back to the nominal
    /// `ppgFs` when there aren't enough / plausible times (e.g. BLE, or a fresh
    /// buffer). A real 29.2 fps camera then scales bpm by the true rate, not 30.
    private func effectiveFs() -> Double {
        let nominal = Double(max(1, ppgFs))
        let cutoff = (greenWindowT.last ?? 0) - hrWindowS * DSPConstants.usPerS
        var diffs: [Double] = []
        var i = greenWindowT.count - 1
        while i >= 1, greenWindowT[i] >= cutoff {
            let d = greenWindowT[i] - greenWindowT[i - 1]
            if d > 0 { diffs.append(d) }
            i -= 1
        }
        guard diffs.count >= 8 else { return nominal }
        let md = median(diffs)
        guard md > 0 else { return nominal }
        let fs = DSPConstants.usPerS / md
        // Only trust it within a sane band around the nominal rate; a gap-inflated
        // median or a stray timestamp shouldn't halve/double the reported rate.
        return (fs >= nominal * 0.5 && fs <= nominal * 1.5) ? fs : nominal
    }

    private func tailWindow(seconds: Double) -> [Double] {
        guard let last = greenWindowT.last else { return greenWindow }
        let cutoff = last - seconds * DSPConstants.usPerS
        var out: [Double] = []
        var i = greenWindowT.count - 1
        while i >= 0, greenWindowT[i] >= cutoff {
            out.append(greenWindow[i])
            i -= 1
        }
        return out.reversed()
    }

    private func trimWindows() {
        // Cap the rolling buffers to the longest window we need.
        let fs = Double(max(1, ppgFs))
        let maxN = Int(respWindowS * fs) + Int(fs)
        if greenWindow.count > maxN {
            let drop = greenWindow.count - maxN
            greenWindow.removeFirst(drop)
            greenWindowT.removeFirst(drop)
        }
    }

    private func pushCapped(_ arr: inout [Double], _ v: Double, cap: Int = 64) {
        arr.append(v)
        if arr.count > cap { arr.removeFirst(arr.count - cap) }
    }
}
