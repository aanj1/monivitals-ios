//
//  RootView.swift
//  MoniVitals
//
//  The main TabView: Home, Measure (live camera pulse), Clips (history), and
//  Settings. Everything is worked out on your phone from the camera.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            MeasureView()
                .tabItem { Label("Measure", systemImage: "heart.text.square") }

            ReviewView()
                .tabItem { Label("Clips", systemImage: "list.bullet.rectangle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear { model.begin() }
    }
}
