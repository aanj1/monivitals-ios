//
//  PpgDSPTests.swift
//  MoniVitalsTests
//
//  Synthetic-pulse coverage for the on-device DSP. All tests build plain arrays
//  (no camera) so the signal processing is fully deterministic:
//   • heart rate on a known-BPM pulse (±2 bpm),
//   • respiratory rate on an amplitude-modulated pulse,
//   • HRV RMSSD/SDNN on known RR intervals,
//   • the contact/quality classifier on good vs flat input.
//

import XCTest
@testable import MoniVitals

final class PpgDSPTests: XCTestCase {

    // MARK: - Contact hysteresis

    /// A brief loss of contact must HOLD the last reading (not flicker to blank);
    /// only a sustained loss (>= the grace window) blanks it.
    func testContactHysteresisHoldsThenBlanks() {
        let engine = MetricsEngine()
        engine.contactOverride = true   // force the gate; isolate the hysteresis
        let fs = 30
        let g = pulse(bpm: 72, seconds: 10, fs: Double(fs), amplitude: 30, dc: 128)
        let r = [Double](repeating: 230, count: g.count)
        engine.ingestPpg(PpgPacket(seq: 0, tUs: 0, sampleRateHz: fs, green: g, red: r, ir: []))
        _ = engine.snapshot(0)                          // prime the HR median (needs >=2)
        XCTAssertNotNil(engine.snapshot(0).hrBpm, "HR present with contact")

        engine.contactOverride = false                  // drop contact
        var s = engine.snapshot(0)                      // tick 1
        for _ in 0..<6 { s = engine.snapshot(0) }       // ticks 2…7 (< grace 8)
        XCTAssertNotNil(s.hrBpm, "held through a brief contact dip")

        _ = engine.snapshot(0)                          // tick 8 → reset
        s = engine.snapshot(0)                          // tick 9 → blank
        XCTAssertNil(s.hrBpm, "blanked after sustained loss")
    }

    /// A mere contact override (camera state pinned "measuring") must NOT bypass
    /// the clean-signal gate — only the BLE device source may, because the quality
    /// classifier is camera-tuned.
    func testContactOverrideAloneDoesNotBypassQualityGate() {
        let engine = MetricsEngine()
        engine.contactOverride = true
        let fs = 30
        // A readable pulse on the green channel but a dark red channel: the
        // classifier scores this below minQualityForVitals.
        let g = pulse(bpm: 72, seconds: 10, fs: Double(fs), amplitude: 3, dc: 200)
        let r = [Double](repeating: 5, count: g.count)
        engine.ingestPpg(PpgPacket(seq: 0, tUs: 0, sampleRateHz: fs, green: g, red: r, ir: []))
        _ = engine.snapshot(0)
        XCTAssertNil(engine.snapshot(0).hrBpm, "no fresh estimates on a sub-threshold signal")

        engine.isBleSource = true                       // device source: gate bypassed
        _ = engine.snapshot(0)
        XCTAssertNotNil(engine.snapshot(0).hrBpm, "BLE source bypasses the camera-tuned gate")
    }

    /// A held HR must not stay pinned forever: when fresh estimates keep failing
    /// (here: the window goes dead flat) the held value blanks after ~10 s of
    /// staleness, exactly like HRV.
    func testHeldHeartRateBlanksWhenStale() {
        let engine = MetricsEngine()
        engine.isBleSource = true
        engine.contactOverride = true
        let fs = 30
        let g = pulse(bpm: 72, seconds: 10, fs: Double(fs), amplitude: 30, dc: 128)
        let r = [Double](repeating: 230, count: g.count)
        engine.ingestPpg(PpgPacket(seq: 0, tUs: 0, sampleRateHz: fs, green: g, red: r, ir: []))
        _ = engine.snapshot(0)                          // prime the HR median (needs >=2)
        XCTAssertNotNil(engine.snapshot(0).hrBpm, "HR present on a clean pulse")

        // Replace the window with a dead-flat signal: fresh estimates now fail,
        // so the engine holds the last value — but only for the stale limit.
        let flat = [Double](repeating: 128, count: g.count)
        engine.ingestPpg(PpgPacket(seq: 1, tUs: 10_000_000, sampleRateHz: fs,
                                   green: flat, red: r, ir: []))
        var s = engine.snapshot(0)
        XCTAssertNotNil(s.hrBpm, "held while fresh estimates fail briefly")
        for _ in 0..<45 { s = engine.snapshot(0) }      // ride past the stale limit
        XCTAssertNil(s.hrBpm, "blanked after sustained staleness")
    }

    // MARK: - Synthetic signal helpers

    /// A clean sinusoidal pulse at `bpm` for `seconds` at sample rate `fs`.
    private func pulse(bpm: Double, seconds: Double, fs: Double,
                       amplitude: Double = 1, dc: Double = 0) -> [Double] {
        let n = Int(seconds * fs)
        let f = bpm / 60.0
        var out = [Double]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / fs
            out.append(dc + amplitude * sin(2 * .pi * f * t))
        }
        return out
    }

    // MARK: - Heart rate

    func testHeartRateOnKnownPulse60() {
        let s = pulse(bpm: 60, seconds: 12, fs: 30)
        let bpm = PpgHeartRate.estimate(s, fs: 30)
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm ?? 0, 60, accuracy: 2)
    }

    func testHeartRateOnKnownPulse75() {
        let s = pulse(bpm: 75, seconds: 12, fs: 30)
        let bpm = PpgHeartRate.estimate(s, fs: 30)
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm ?? 0, 75, accuracy: 2)
    }

    func testHeartRateOnKnownPulse100WithDC() {
        // Real camera samples ride a large DC brightness; detrending must handle it.
        let s = pulse(bpm: 100, seconds: 12, fs: 30, amplitude: 5, dc: 200)
        let bpm = PpgHeartRate.estimate(s, fs: 30)
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm ?? 0, 100, accuracy: 2)
    }

    func testHeartRateStableIntervalsRejectExtraNoisePeak() {
        // A false local peak creates one short and one long interval. The reported
        // cadence should stay on the dominant 800 ms rhythm, not jump.
        let cleaned = PpgHeartRate.stableIntervals([0.80, 0.80, 0.40, 1.20, 0.80, 0.82, 0.79])
        XCTAssertEqual(cleaned.count, 5)
        XCTAssertEqual(median(cleaned), 0.80, accuracy: 0.02)
    }

    func testHeartRateNilOnTooShort() {
        let s = pulse(bpm: 70, seconds: 1, fs: 30)
        XCTAssertNil(PpgHeartRate.estimate(s, fs: 30))
    }

    func testHeartRateReporterSmoothsAndClears() {
        let r = PulseHeartRateReporter()
        XCTAssertNil(r.push(72))          // <2 samples
        XCTAssertNotNil(r.push(74))       // now has median
        _ = r.push(73)
        XCTAssertEqual(r.value() ?? 0, 73, accuracy: 2)
        r.reset()
        XCTAssertNil(r.value())
    }

    // MARK: - Respiratory rate

    func testRespiratoryRateOnAmplitudeModulatedPulse() {
        // Pulse at 72 bpm whose amplitude swells at 15 breaths/min (0.25 Hz).
        let fs = 30.0
        let seconds = 40.0
        let hrF = 72.0 / 60.0
        let respBpm = 15.0
        let respF = respBpm / 60.0
        let n = Int(seconds * fs)
        var s = [Double]()
        for i in 0..<n {
            let t = Double(i) / fs
            let envelope = 1.0 + 0.6 * sin(2 * .pi * respF * t)
            s.append(200 + envelope * 5 * sin(2 * .pi * hrF * t))
        }
        // Feed the pulse's amplitude/baseline modulation through the resp band.
        let rr = RespiratoryRate.estimate(s, fs: fs)
        XCTAssertNotNil(rr)
        XCTAssertEqual(rr ?? 0, respBpm, accuracy: 3)
    }

    func testRespiratoryRateNilOnTooShort() {
        let s = pulse(bpm: 72, seconds: 5, fs: 30)
        XCTAssertNil(RespiratoryRate.estimate(s, fs: 30))
    }

    // MARK: - HRV

    func testRmssdOnKnownIntervals() {
        // RR = 800, 810, 790, 805 ms. Successive diffs: 10, -20, 15.
        // RMSSD = sqrt((100 + 400 + 225)/3) = sqrt(241.6667) ≈ 15.5456.
        let rr = [800.0, 810, 790, 805]
        XCTAssertEqual(HeartRateVariability.rmssd(rr), (725.0 / 3).squareRoot(), accuracy: 1e-6)
    }

    func testSdnnOnKnownIntervals() {
        let rr = [800.0, 810, 790, 805]
        // Population std-dev of the intervals.
        XCTAssertEqual(HeartRateVariability.sdnn(rr), stddev(rr), accuracy: 1e-9)
        XCTAssertGreaterThan(HeartRateVariability.sdnn(rr), 0)
    }

    func testHrvComputeNilBelowMinimumIntervals() {
        XCTAssertNil(HeartRateVariability.compute(rrMs: [800, 810]))
        XCTAssertNil(HeartRateVariability.compute(rrMs: [800, 810, 790]))
        XCTAssertNotNil(HeartRateVariability.compute(
            rrMs: [800, 810, 790, 805, 795, 815, 800, 790]))
    }

    func testHrvComputeRejectsImplausiblyHighResult() {
        // Alternating short/long intervals (missed-beat pattern) would produce an
        // RMSSD in the hundreds; the artifact criteria must suppress it.
        let rr: [Double] = [600, 1080, 600, 1080, 600, 1080, 600, 1080, 600, 1080]
        XCTAssertNil(HeartRateVariability.compute(rrMs: rr))
    }

    func testSuccessiveDiffsDropArtifactPairs() {
        // 800→1200 is a +40% jump (missed beat) — that pair must be dropped while
        // the small physiological differences survive.
        let diffs = HeartRateVariability.successiveDiffs([800, 810, 1200, 805, 795])
        XCTAssertFalse(diffs.contains { abs($0) > 200 })
        XCTAssertTrue(diffs.contains(10))
    }

    func testHrvFiltersSingleBadBeatOutlier() {
        let rr = [800.0, 805, 795, 1200, 810, 790, 800]
        let cleaned = HeartRateVariability.cleanedIntervals(rr)
        XCTAssertFalse(cleaned.contains(1200))
        XCTAssertEqual(cleaned.count, 6)
    }

    func testRrIntervalsFromBeatsMarksImplausibleAsNaN() {
        // Beats 1 s apart (1000 ms) plus one absurd 5 s gap. The gap becomes a NaN
        // placeholder (not silently dropped) so pairing still knows the intervals
        // around it were never adjacent.
        let beats = [0.0, 1_000_000, 2_000_000, 7_000_000]
        let rr = HeartRateVariability.rrIntervalsMs(fromBeatsUs: beats)
        XCTAssertEqual(rr.count, 3)
        XCTAssertEqual(Array(rr.prefix(2)), [1000, 1000])
        XCTAssertTrue(rr[2].isNaN)
    }

    func testSuccessiveDiffsSkipPairsAcrossNaNPlaceholder() {
        // A NaN hole marks a dropped (implausible) interval; the survivors either
        // side of it were never adjacent, so no difference may be formed across it.
        let diffs = HeartRateVariability.successiveDiffs([800, 810, Double.nan, 900, 910])
        XCTAssertEqual(diffs, [10, 10])
    }

    func testHrvReporterOverBeats() {
        let rep = HeartRateVariabilityReporter()
        var t = 0.0
        for _ in 0..<20 {
            rep.addBeat(t)
            t += 850_000 // ~70.6 bpm
        }
        let res = rep.result()
        XCTAssertNotNil(res)
        XCTAssertGreaterThanOrEqual(res?.rmssdMs ?? -1, 0)
    }

    // MARK: - Beat / foot detectors

    /// CRITICAL-1 regression: a CONSTANT-HR pulse at a rate whose IBI is NOT a whole
    /// number of frames (70 bpm ⇒ 857.14 ms vs the 33.3 ms grid) has ZERO true HRV,
    /// yet snapping peaks to the frame grid alternates IBIs by ±one frame and fakes
    /// RMSSD in the ~25 ms range. Parabolic sub-sample interpolation must drive that
    /// floor well below 5 ms.
    func testConstantHeartRateHasNearZeroRmssd() {
        let det = PPGBeatDetector()
        let fs = 30.0
        let bpm = 70.0                    // 857.14 ms IBI: does not divide the frame grid
        let f = bpm / 60.0
        var ibis: [Double] = []
        var lastBeatUs: Double?
        for i in 0..<Int(fs * 40) {       // 40 s → plenty of clean intervals
            let tUs = Double(i) / fs * 1_000_000
            if let beat = det.process(sin(2 * .pi * f * tUs / 1_000_000), tUs: tUs) {
                if let last = lastBeatUs { ibis.append((beat - last) / 1000.0) }
                lastBeatUs = beat
            }
        }
        // Drop the first couple (threshold warm-up) and measure RMSSD directly.
        let steady = Array(ibis.dropFirst(2))
        XCTAssertGreaterThanOrEqual(steady.count, 20, "enough clean intervals to judge")
        let rmssd = HeartRateVariability.rmssd(steady)
        // Sanity: the mean IBI must still be ~857 ms (we didn't distort the rate).
        XCTAssertEqual(median(steady), 60_000.0 / bpm, accuracy: 20)
        // The proof: on a perfectly regular pulse RMSSD collapses toward zero. Without
        // interpolation this sat at ~25 ms (a full frame of grid jitter).
        XCTAssertLessThan(rmssd, 5.0, "grid-quantization HRV floor removed (was ~25 ms)")
    }

    /// CRITICAL-2 regression: a dropped-frame time gap fed to the beat pipeline must
    /// NOT manufacture a phantom fast beat. We run a clean pulse through PPGEngine via
    /// a packet stream containing a large PTS jump and assert bpm never spikes.
    @MainActor
    func testDroppedFrameGapDoesNotSpikeRate() {
        let engine = PPGEngine()
        let fs = 30.0
        let bpm = 72.0
        let f = bpm / 60.0
        var maxBpm = 0.0
        var frame = 0
        // Feed the engine a covered-lens pulse; at ~12 s introduce a 200 ms gap
        // (≈6 dropped frames) by jumping the timestamp, then continue the pulse.
        var tUs = 0.0
        for step in 0..<Int(fs * 24) {
            // 200 ms discontinuity midway through.
            if step == Int(fs * 12) { tUs += 200_000 } else if step > 0 { tUs += 1_000_000 / fs }
            let ac = 5.0 * sin(2 * .pi * f * tUs / 1_000_000)
            // Bright red DC → finger present; green carries the pulse ripple.
            let f2 = PPGFrame(tUs: tUs, red: 230, green: 200 + ac, satFraction: 0.02)
            engine.testFeed(f2)
            if let b = engine.bpm { maxBpm = max(maxBpm, b) }
            frame += 1
        }
        // A phantom beat across the gap would read as a very short IBI → a huge bpm.
        XCTAssertLessThan(maxBpm, 200, "no phantom rate spike across the dropped-frame gap")
    }

    /// CRITICAL-3 regression: real per-sample timestamps must flow through the packet
    /// so the DSP scales rate off ACTUAL fps, not a hard-coded 30. Here the true rate
    /// is 25 fps but sampleRateHz still claims 30; with honest `timesUs` the HR must
    /// track the real 60 bpm rather than 60 × (30/25) = 72.
    func testPerSampleTimestampsScaleRate() {
        let engine = MetricsEngine()
        engine.isBleSource = true          // bypass camera-tuned quality gate for the test
        engine.contactOverride = true
        let trueFs = 25.0                  // real capture rate
        let bpm = 60.0
        let f = bpm / 60.0
        let seconds = 12.0
        let n = Int(seconds * trueFs)
        var green: [Double] = []
        var times: [Double] = []
        for i in 0..<n {
            let tUs = Double(i) / trueFs * 1_000_000
            green.append(128 + 30 * sin(2 * .pi * f * tUs / 1_000_000))
            times.append(tUs)
        }
        let red = [Double](repeating: 230, count: n)
        // sampleRateHz deliberately WRONG (claims 30) — timesUs must win.
        engine.ingestPpg(PpgPacket(seq: 0, tUs: 0, sampleRateHz: 30,
                                   green: green, red: red, ir: [], timesUs: times))
        _ = engine.snapshot(times.last ?? 0)
        let hr = engine.snapshot(times.last ?? 0).hrBpm
        XCTAssertNotNil(hr)
        // With honest times we get ~60; using the bogus 30 fps would read ~72.
        XCTAssertEqual(hr ?? 0, bpm, accuracy: 4)
    }

    /// 150 bpm ⇒ 400 ms IBIs, well above the ~285 ms refractory (60/210 bpm). The
    /// old refractory was derived from minBpm (750 ms) and halved every rate above
    /// ~80 bpm — this pins the fix.
    func testBeatDetectorFollows150Bpm() {
        let det = PPGBeatDetector()
        let fs = 30.0
        let f = 150.0 / 60.0
        var beats = 0
        for i in 0..<Int(fs * 10) {
            let t = Double(i) / fs
            if det.process(sin(2 * .pi * f * t), tUs: t * 1_000_000) != nil { beats += 1 }
        }
        // 25 cycles in 10 s; allow slack for threshold warm-up at the start.
        XCTAssertGreaterThanOrEqual(beats, 20)
        XCTAssertLessThanOrEqual(beats, 27)
    }

    /// A placement transient seeds the foot detector's slope threshold far above
    /// any real pulse slope. Search-back decay must bring it back down so beats
    /// are detected again instead of staying pinned off forever.
    func testFootDetectorThresholdRecoversAfterTransient() {
        let fs = 30.0
        let det = PpgFootDetector(fs: fs)
        let dtUs = DSPConstants.usPerS / fs
        let hrF = 72.0 / 60.0
        var t = 0.0
        var i = 0
        var footTimes: [Double] = []
        func feed(_ y: Double) {
            if let f = det.process(y, t) { footTimes.append(f) }
            t += dtUs
            i += 1
        }
        // 3 s of small clean pulse (covers the 1.5 s learning window).
        while t < 3.0e6 { feed(128 + 5 * sin(2 * .pi * hrF * Double(i) / fs)) }
        // Placement transient: the brightness steps up hugely in one frame, then
        // the same small pulse rides the new level for 25 s.
        while t < 28.0e6 { feed(3128 + 5 * sin(2 * .pi * hrF * Double(i) / fs)) }
        // Without decay no foot is ever accepted after the step; with it the
        // threshold recovers within a few seconds and beats resume (~12 in the
        // final 10 s at 72 bpm).
        let recovered = footTimes.filter { $0 > 18.0e6 }
        XCTAssertGreaterThanOrEqual(recovered.count, 8, "threshold recovered after transient")
    }

    // MARK: - Signal quality / contact

    func testQualityHighOnGoodPulse() {
        // Bright, rippling, steady — a fingertip covering the torch.
        let fs = 30.0
        var s = [Double]()
        let hrF = 72.0 / 60.0
        for i in 0..<Int(fs * 2) {
            let t = Double(i) / fs
            s.append(230 + 3 * sin(2 * .pi * hrF * t))
        }
        let score = SignalQuality.classify(brightness: s, pulse: s)
        XCTAssertTrue(score.contact)
        XCTAssertGreaterThan(score.quality, 50)
    }

    func testQualityLowOnFlatDarkInput() {
        // Dim and dead-flat — no finger present.
        let s = [Double](repeating: 12, count: 60)
        let score = SignalQuality.classify(brightness: s, pulse: s)
        XCTAssertFalse(score.contact)
        XCTAssertLessThan(score.quality, 40)
    }

    func testQualityReporterRolls() {
        let rep = SignalQualityReporter(fs: 30)
        for _ in 0..<10 { rep.push(red: 230, green: 230) }
        // Bright but perfectly flat → no perfusion → no contact.
        XCTAssertFalse(rep.score().contact)
    }

    func testPPGQualityEstimatorRequiresRealPulse() {
        let fs = 30.0
        let seconds = 5.0
        let n = Int(fs * seconds)
        let dts = [Double](repeating: 1_000_000 / fs, count: n)
        let hrF = 72.0 / 60.0
        let filtered = (0..<n).map { i in
            sin(2 * .pi * hrF * Double(i) / fs)
        }
        let green = filtered.map { 180 + 8 * $0 }
        let estimator = PPGQualityEstimator(config: PPGConfig())
        var good = PPGQualityScore.zero
        for _ in 0..<10 {
            good = estimator.score(filtered: filtered, green: green, dts: dts,
                                   satFraction: 0.01, motionLevel: 0, fingerProb: 0.95, fs: fs)
        }

        estimator.reset()
        let flatFiltered = [Double](repeating: 0, count: n)
        let flatGreen = [Double](repeating: 180, count: n)
        var flat = PPGQualityScore.zero
        for _ in 0..<10 {
            flat = estimator.score(filtered: flatFiltered, green: flatGreen, dts: dts,
                                   satFraction: 0, motionLevel: 0, fingerProb: 0.95, fs: fs)
        }

        XCTAssertGreaterThan(good.composite, 0.55)
        XCTAssertLessThan(flat.composite, 0.25)
        XCTAssertGreaterThan(good.composite, flat.composite + 0.30)
    }
}
