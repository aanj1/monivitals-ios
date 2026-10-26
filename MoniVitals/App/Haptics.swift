//
//  Haptics.swift
//  MoniVitals
//
//  Thin wrapper over UIKit feedback generators so key actions (save a clip, accept the
//  onboarding gate, add a calibration reading) feel tactile. Deliberately restrained —
//  used only on meaningful, user-initiated commits, never on passive value updates.
//

import UIKit

enum Haptics {
    /// A light selection/confirmation tap (e.g. add a calibration reading, drop a marker).
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A firmer tap for a primary commit (start/finish a clip, accept onboarding).
    static func commit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Success notification (e.g. a calibration fit saved).
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning notification (e.g. a destructive action was confirmed).
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
