//
//  MotionMonitor.swift
//  MoniVitals
//
//  Reads the phone's accelerometer to tell how still your hand is while
//  measuring. A steady hold gives a clean pulse; a shaky one adds noise. We turn
//  the shake into a simple 0…100 "movement" number the UI can react to.
//
//  Fails quietly when motion sensing isn't available (e.g. the Simulator): it
//  just reports 0 movement rather than crashing.
//

import CoreMotion
import Foundation

/// Live movement reporter backed by CoreMotion. Thread-safe reads via a lock.
final class MotionMonitor {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var recent: [Double] = []
    private let cap = 25            // ~0.5 s at 50 Hz
    private var running = false

    /// Whether the device exposes an accelerometer at all.
    var isAvailable: Bool { manager.isAccelerometerAvailable }

    func start() {
        guard manager.isAccelerometerAvailable, !running else { return }
        running = true
        manager.accelerometerUpdateInterval = 1.0 / 50.0
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            // Deviation from 1 g at rest, in "milli-g".
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let deviation = abs(mag - 1.0) * 1000.0
            self.lock.lock()
            self.recent.append(deviation)
            if self.recent.count > self.cap { self.recent.removeFirst(self.recent.count - self.cap) }
            self.lock.unlock()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopAccelerometerUpdates()
        lock.lock(); recent.removeAll(); lock.unlock()
    }

    /// Current movement level, 0 (perfectly still) … 100 (very shaky).
    func movement() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !recent.isEmpty else { return 0 }
        let avg = recent.reduce(0, +) / Double(recent.count)
        // Map ~0…200 milli-g of jitter onto 0…100 (matches Signal quality's scale).
        return Int(clamp(avg / 200.0 * 100.0, 0, 100).rounded())
    }
}
