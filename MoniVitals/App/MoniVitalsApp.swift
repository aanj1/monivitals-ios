//
//  MoniVitalsApp.swift
//  MoniVitals
//
//  SwiftUI app entry point. Hosts the single shared AppModel and shows the
//  friendly first-run welcome (fingertip explanation + acknowledgement) once.
//
//  MoniVitals works everything out on your phone. It's for wellbeing, not a
//  substitute for medical care.
//

import SwiftUI

@main
struct MoniVitalsApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.needsOnboarding {
                    OnboardingView()
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .mvTheme()
        }
        .onChange(of: scenePhase) { phase in
            // Release the camera + turn the torch off while the app is suspended,
            // and pick measuring back up cleanly on return. `.inactive` (an incoming
            // call, Control Center / Notification Center pull) gets a lighter pause so
            // the torch doesn't stay lit behind the interruption, while a brief blip
            // that returns straight to `.active` resumes the session.
            switch phase {
            case .active:     model.resumeFromBackground()
            case .inactive:   model.pauseForInterruption()
            case .background: model.pauseForBackground()
            @unknown default: break
            }
        }
    }
}
