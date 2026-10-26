//
//  Theme.swift
//  MoniVitals
//
//  Single source of truth for the MoniVitals light theme + brand palette.
//  Derived from the logo: deep indigo navy + vivid magenta on white.
//  Every view should use `MV.*` tokens instead of hardcoded/system colors.
//
//  MoniVitals is a research / educational tool, NOT a medical device.
//

import SwiftUI

// MARK: - Hex color init

extension Color {
    /// Create a Color from a 24-bit hex value, e.g. `Color(hex: 0x261A64)`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Brand palette (MV = MoniVitals)

enum MV {
    // Brand — bright enough to read as text/emphasis on the dark canvas.
    static let navy       = Color(hex: 0xE9E7FB)   // titles / emphasis (light indigo-white)
    static let navyDeep   = Color(hex: 0x1A1550)   // deep gradient end
    static let magenta    = Color(hex: 0xF0356E)   // vivid accent (heartbeat)
    static let pink       = Color(hex: 0xC85C86)   // mid gradient

    // Surfaces (dark theme — Cardiographer-style near-black canvas)
    static let bg         = Color(hex: 0x0A0B0E)   // app background
    static let surface    = Color(hex: 0x16181E)   // cards / grouped panels
    static let surfaceAlt = Color(hex: 0x1F222B)   // nested fills
    static let separator  = Color(hex: 0x2B2F3A)

    // Text
    static let ink        = Color(hex: 0xF2F3F8)   // primary text (near-white)
    static let inkMuted   = Color(hex: 0x9BA0B0)   // secondary text

    // Semantic status
    static let good       = Color(hex: 0x35C77A)   // ok / good signal (green)
    static let warn       = Color(hex: 0xF5A623)   // caution / fair signal (amber)
    static let bad        = Color(hex: 0xFF5A5F)   // error / poor signal (red)

    // Waveform traces (on the dark oscilloscope)
    static let ecg        = Color(hex: 0x8E86E8)   // secondary trace — indigo
    static let ppg        = Color(hex: 0x35C77A)   // PPG pulse — green
    static let bioz       = Color(hex: 0x2CC7C7)   // BioZ — teal

    // Primary tint used app-wide (nav bars, buttons, controls)
    static let accent     = magenta

    // Spacing scale (use these, not magic numbers).
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32

    // Corner radii.
    static let rCard: CGFloat = 18
    static let rTile: CGFloat = 16
    static let rControl: CGFloat = 12

    // Rounded numeric style for metric values.
    static func number(_ size: CGFloat = 24) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    // The signature navy→magenta gradient (the logo "M").
    static let brandGradient = LinearGradient(
        colors: [navyDeep, magenta],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Reusable view styling

extension View {
    /// Standard MoniVitals card: dark surface, soft rounded corners, hairline border,
    /// and a gentle elevation shadow for depth on the near-black canvas.
    func mvCard(padding: CGFloat = 16, radius: CGFloat = MV.rCard) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(MV.surface)
                    .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(MV.separator, lineWidth: 1)
            )
    }

    /// Apply the MoniVitals dark theme globally (tint + forced dark scheme so the
    /// near-black palette + system chrome stay consistent).
    func mvTheme() -> some View {
        self
            .tint(MV.accent)
            .preferredColorScheme(.dark)
    }
}
