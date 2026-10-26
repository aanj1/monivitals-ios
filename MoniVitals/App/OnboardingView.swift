//
//  OnboardingView.swift
//  MoniVitals
//
//  First-run welcome: one friendly screen explaining fingertip measurement, a
//  single acknowledgement, and warm rationale for the camera. Acceptance is
//  persisted so it's shown only once. Everything is worked out on your phone;
//  readings leave it only if the user turns on the optional cloud backup.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MV.s24) {
                    header

                    VStack(alignment: .leading, spacing: MV.s12) {
                        HStack(spacing: MV.s8) {
                            IconBadge(systemName: "hand.point.up.left.fill", tint: MV.magenta, size: 30)
                            Text("How it works")
                                .font(.headline)
                                .foregroundStyle(MV.navy)
                        }
                        Text("""
                        Rest a fingertip gently over your phone's rear camera. The \
                        light shines through your skin, and MoniVitals watches the \
                        tiny changes with each heartbeat to work out your heart rate, \
                        breathing rate, and heart-rate variability. Hold still for a \
                        few seconds and the numbers settle.
                        """)
                        .font(.callout)
                        .foregroundStyle(MV.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mvCard()

                    VStack(alignment: .leading, spacing: MV.s12) {
                        HStack(spacing: MV.s8) {
                            IconBadge(systemName: "lock.shield", tint: MV.navy, size: 30)
                            Text("Private by design")
                                .font(.headline)
                                .foregroundStyle(MV.navy)
                        }
                        Text("""
                        Everything is worked out right here on your phone and no \
                        images are kept. Your readings stay on this phone unless you \
                        turn on optional cloud backup in Settings. MoniVitals is for \
                        curiosity and wellbeing, and isn't a substitute for medical care.
                        """)
                        .font(.callout)
                        .foregroundStyle(MV.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mvCard()
                }
                .padding(MV.s16)
            }
            .background(MV.bg)

            // Pinned action bar — always visible; tapping "Get started" is the
            // acknowledgement, so there's nothing to toggle and no way to get stuck.
            VStack(spacing: MV.s8) {
                Button {
                    Haptics.commit()
                    model.acceptOnboarding()
                } label: {
                    Text("Get started")
                }
                .buttonStyle(PrimaryButtonStyle())

                Text("For wellbeing and curiosity — not a substitute for medical care.")
                    .font(.caption)
                    .foregroundStyle(MV.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(MV.s16)
            .background(MV.bg)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MV.s12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 110)
            Text("Welcome to MoniVitals")
                .font(.largeTitle.bold())
                .foregroundStyle(MV.navy)
            Text("Measure your heart rate from your fingertip, right on your phone.")
                .font(.callout)
                .foregroundStyle(MV.inkMuted)
        }
    }
}
