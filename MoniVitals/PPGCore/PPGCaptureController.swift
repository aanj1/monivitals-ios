//
//  PPGCaptureController.swift
//  MoniVitals — PPGCore
//
//  AVFoundation capture tuned for a stable fingertip PPG: fixed frame rate, torch
//  on, and — once AE/AWB/focus have settled — LOCKED so the camera stops quietly
//  re-adjusting the waveform mid-measurement. Emits one averaged ROI sample per
//  frame (R & G) plus a saturation fraction, on the main queue.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// One camera frame reduced to what the pipeline needs.
struct PPGFrame {
    var tUs: Double        // presentation timestamp, microseconds
    var red: Double        // mean red over ROI, 0…255
    var green: Double      // mean green over ROI, 0…255
    var satFraction: Double // fraction of ROI pixels clipped (0…1)
}

final class PPGCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Frame callback (delivered on MAIN).
    var onFrame: ((PPGFrame) -> Void)?
    /// Called (on MAIN) when no usable camera exists (Simulator / permission / hardware).
    var onNoCamera: ((String) -> Void)?
    /// Small live ROI thumbnail (delivered on MAIN, ~10 fps) for the scope preview.
    var onPreview: ((CGImage) -> Void)?

    private var cfg: PPGConfig
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.monivitals.ppgcore.capture")
    /// Off-capture-queue render so CGImage creation never competes with ROI averaging
    /// (which would risk dropped frames that corrupt PPG timing).
    private let previewQueue = DispatchQueue(label: "com.monivitals.ppgcore.preview", qos: .utility)
    private var device: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private var configured = false
    private var framesSeen = 0
    private var locked = false
    private var torchOn = true
    private var previewCounter = 0
    /// Single-in-flight guard for the preview render (touched only on `queue`), so late
    /// renders can't pile up and exhaust the capture pool via retained pixel buffers.
    private var previewInFlight = false
    /// Guards against re-entrant start() double-starting the session / torch (on `queue`).
    private var running = false
    /// Registered once so a hardware reset / another app seizing the camera can be recovered.
    private var observers: [NSObjectProtocol] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(config: PPGConfig = PPGConfig()) { self.cfg = config }

    /// Switch the presence gating between fingertip and palm thresholds. The lock
    /// gate reads `cfg` on the capture queue, so the mutation hops there too.
    func setScanMode(_ mode: ScanMode) {
        queue.async { [weak self] in self?.cfg.scanMode = mode }
    }

    func start() {
        #if targetEnvironment(simulator)
        DispatchQueue.main.async { self.onNoCamera?("A heart-rate estimate needs a real iPhone camera.") }
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: queue.async { [weak self] in self?.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                guard let self else { return }
                if ok { self.queue.async { self.configureAndRun() } }
                else { DispatchQueue.main.async { self.onNoCamera?("Turn on camera access in Settings.") } }
            }
        default:
            DispatchQueue.main.async { self.onNoCamera?("Turn on camera access in Settings.") }
        }
        #endif
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorch(false)
            // Hand the camera back to auto so the NEXT measurement re-settles + re-locks
            // rather than carrying over a stale exposure lock.
            if let dev = self.device, let _ = try? dev.lockForConfiguration() {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                dev.unlockForConfiguration()
            }
            if self.session.isRunning { self.session.stopRunning() }
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.locked = false
            self.framesSeen = 0
            // Allow a later start() to re-run; observers stay bound to the persistent
            // session for the next run and are torn down in deinit.
            self.running = false
        }
    }

    // MARK: - setup (on `queue`)

    private func configureAndRun() {
        // Idempotent: a re-entrant start() must not double-start the session, double-attach
        // the delegate, or double-light the torch. Cleared in stop().
        guard !running else { return }
        running = true
        if configured {
            // Re-attach the delegate cleared on stop(); `locked`/`framesSeen` were reset
            // there so this session re-settles + re-locks exposure instead of carrying a
            // stale lock.
            output?.setSampleBufferDelegate(self, queue: queue)
            if !session.isRunning { session.startRunning() }
            setTorch(true)
            return
        }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            running = false
            DispatchQueue.main.async { self.onNoCamera?("This iPhone's camera isn't available.") }
            return
        }
        device = dev
        session.beginConfiguration()
        session.sessionPreset = .low
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            running = false
            DispatchQueue.main.async { self.onNoCamera?("Couldn't start the camera. Try again.") }
            return
        }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        output = out
        session.commitConfiguration()
        configured = true

        // Lock a steady frame rate so the DSP has a known fs.
        if let _ = try? dev.lockForConfiguration() {
            let d = CMTime(value: 1, timescale: CMTimeScale(cfg.targetFps))
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
            dev.unlockForConfiguration()
        }
        session.startRunning()
        setTorch(true)
        addSessionObservers()
    }

    /// Observe session faults so a hardware reset or another app grabbing the camera
    /// doesn't leave us dead with the torch stuck on. Registered once (on `queue`);
    /// handlers hop back onto `queue` before touching session/torch state.
    private func addSessionObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session,
                                        queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.running else { return }
                // Recover the dropped session the same way configureAndRun starts it.
                if !self.session.isRunning { self.session.startRunning() }
                self.setTorch(true)
            }
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session,
                                        queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.setTorch(false) }
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session,
                                        queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.running else { return }
                if !self.session.isRunning { self.session.startRunning() }
                self.setTorch(true)
            }
        })
    }

    private func removeSessionObservers() {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    deinit { removeSessionObservers() }

    private func setTorch(_ on: Bool) {
        guard let dev = device, dev.hasTorch else { return }
        guard let _ = try? dev.lockForConfiguration() else { return }
        if on { try? dev.setTorchModeOn(level: 1.0) } else { dev.torchMode = .off }
        dev.unlockForConfiguration()
        torchOn = on
    }

    /// Flash control: flip the torch on/off (on the capture queue).
    func toggleTorch() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorch(!self.torchOn)
        }
    }

    /// Recalibrate: hand the camera back to continuous auto and clear the lock so it
    /// re-settles + re-locks a fresh exposure/white-balance (for a bad lock or drift).
    func recalibrate() {
        queue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            if let _ = try? dev.lockForConfiguration() {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                dev.unlockForConfiguration()
            }
            self.locked = false
            self.framesSeen = 0
        }
    }

    /// Build a small ROI thumbnail (~10 fps) for the scope preview and hand it to MAIN.
    /// The CIImage is built on the capture queue (it retains the pixel buffer, so the
    /// buffer is safe to release when the callback returns), but the expensive
    /// CIImage→CGImage render is dispatched to `previewQueue` so it never competes with
    /// ROI averaging on the capture queue.
    private func emitPreview(_ pb: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pb)
        let ext = ci.extent
        guard ext.width > 1, ext.height > 1 else { return }
        let frac = max(0.05, min(1.0, cfg.roiFraction))
        let rw = ext.width * frac, rh = ext.height * frac
        let crop = ci.cropped(to: CGRect(x: ext.midX - rw / 2, y: ext.midY - rh / 2, width: rw, height: rh))
        let scale = 72.0 / max(rw, rh)
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Single-in-flight: if the last render hasn't finished, skip this one rather than
        // queueing another CIImage (which retains `pb`) and starving the capture pool.
        // `previewInFlight` is touched only on the capture `queue`, where emitPreview runs.
        guard !previewInFlight else { return }
        previewInFlight = true
        previewQueue.async { [weak self] in
            guard let self else { return }
            if let cg = self.ciContext.createCGImage(scaled, from: scaled.extent) {
                DispatchQueue.main.async { [weak self] in self?.onPreview?(cg) }
            }
            // Clear the flag back on the capture queue so it's only ever touched there.
            self.queue.async { [weak self] in self?.previewInFlight = false }
        }
    }

    /// After `settleSeconds`, freeze AE/AWB/focus so the camera stops re-tuning the
    /// waveform. Called once, from the capture callback path.
    /// - Parameter red: mean red ROI (0…255). The settle window only advances while a
    ///   fingertip is actually covering the lens (bright red DC); starting before the
    ///   finger arrives would otherwise freeze a room exposure. If not covered, the
    ///   window restarts so it re-settles once the finger is on the lens.
    private func lockExposureIfSettled(_ tUs: Double, red: Double) {
        guard !locked, let dev = device else { return }
        // Only count settle frames on a covered/lit lens (red DC above the active
        // mode's presence threshold — fingertip contact or palm hover). Reset
        // otherwise so the window starts fresh when the finger/palm arrives.
        guard red >= cfg.presenceEnter * 255 else { framesSeen = 0; return }
        framesSeen += 1
        if Double(framesSeen) < cfg.targetFps * cfg.settleSeconds { return }
        // Wait for AE/AWB to actually converge before freezing — a timer alone can lock a
        // mid-adjustment (bad) exposure, especially if the finger arrives after start.
        if dev.isAdjustingExposure || dev.isAdjustingWhiteBalance { return }
        guard let _ = try? dev.lockForConfiguration() else { return }
        if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
        if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
        dev.unlockForConfiguration()
        locked = true
    }

    // MARK: - delegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tUs = CMTimeGetSeconds(pts) * cfg.usPerS
        // ROI first so the settle/lock decision can see whether the lens is covered.
        guard let m = averageROI(pb) else { return }
        lockExposureIfSettled(tUs, red: m.red)
        let frame = PPGFrame(tUs: tUs, red: m.red, green: m.green, satFraction: m.sat)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }

        // Throttled ROI thumbnail (~10 fps) for the scope preview.
        previewCounter &+= 1
        if previewCounter % 3 == 0, onPreview != nil { emitPreview(pb) }
    }

    /// Center-ROI average of R and G plus the clipped-pixel fraction (BGRA).
    private func averageROI(_ pb: CVPixelBuffer) -> (red: Double, green: Double, sat: Double)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let frac = max(0.05, min(1.0, cfg.roiFraction))
        let rw = Int(Double(w) * frac), rh = Int(Double(h) * frac)
        let x0 = (w - rw) / 2, y0 = (h - rh) / 2
        // Subsample so this stays cheap at 30 fps.
        let step = max(1, min(rw, rh) / 32)

        var rSum = 0.0, gSum = 0.0, n = 0.0, clipped = 0.0
        var y = y0
        while y < y0 + rh {
            let row = ptr + y * stride
            var x = x0
            while x < x0 + rw {
                let px = row + x * 4          // BGRA
                let b = Double(px[0]), g = Double(px[1]), r = Double(px[2])
                rSum += r; gSum += g; n += 1
                if r >= cfg.clipLevel || g >= cfg.clipLevel || b >= cfg.clipLevel { clipped += 1 }
                x += step
            }
            y += step
        }
        guard n > 0 else { return nil }
        return (rSum / n, gSum / n, clipped / n)
    }
}
