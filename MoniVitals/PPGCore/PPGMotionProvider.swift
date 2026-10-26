//
//  PPGMotionProvider.swift
//  MoniVitals — PPGCore
//
//  Rolling 0…1 hand-motion magnitude from the accelerometer. Feeds the quality
//  score's motion penalty. Fails quietly to 0 when CoreMotion is unavailable.
//

import CoreMotion
import Foundation

final class PPGMotionProvider {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    /// Dedicated serial queue for the 50 Hz accelerometer callback — keeps that work
    /// off the main queue (the `NSLock` then genuinely guards the cross-thread read).
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private var recent: [Double] = []
    private var running = false

    /// Latest motion level, 0 (perfectly still) … 1 (very shaky).
    var level: Double {
        lock.lock(); defer { lock.unlock() }
        guard !recent.isEmpty else { return 0 }
        // RMS of recent gravity-removed magnitudes, mapped to 0…1 (~0.3 g = shaky).
        let rms = (recent.reduce(0) { $0 + $1 * $1 } / Double(recent.count)).squareRoot()
        return clamp(rms / 0.3, 0, 1)
    }

    func start() {
        guard manager.isAccelerometerAvailable, !running else { return }
        running = true
        manager.accelerometerUpdateInterval = 1.0 / 50.0
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            // Magnitude minus 1 g gravity baseline.
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let dev = abs(mag - 1.0)
            self.lock.lock()
            self.recent.append(dev)
            if self.recent.count > 25 { self.recent.removeFirst(self.recent.count - 25) }
            self.lock.unlock()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopAccelerometerUpdates()
        lock.lock(); recent.removeAll(); lock.unlock()
    }
}
