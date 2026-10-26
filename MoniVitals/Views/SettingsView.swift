//
//  SettingsView.swift
//  MoniVitals
//
//  Movement sensitivity, appearance, your account (optional cloud backup), your
//  data, and about. Kept as a Form (not a card ScrollView): it uses dense system
//  Pickers/Steppers whose native behaviour we want to preserve. It still wears
//  the light theme — hidden scroll background, MV.bg canvas, MV.surface rows — so
//  it reads like the rest of the app.
//

import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDeleteConfirm = false
    @State private var showPairing = false

    // Account form state
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var accountBusy = false
    @State private var accountError: String?
    @State private var showDeleteAccountConfirm = false
    /// RAW nonce for an in-flight Sign in with Apple request; its SHA-256 hash is
    /// set on the request, the raw value is sent to Firebase to re-hash + compare.
    @State private var appleRawNonce = ""

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                measurementSection
                movementSection
                appearanceSection
                accountSection
                dataSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(MV.bg)
            .tint(MV.accent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings").font(.headline).foregroundStyle(MV.navy)
                }
            }
        }
    }

    private var modelSection: some View {
        Section {
            HStack(spacing: MV.s12) {
                IconBadge(systemName: "cpu", tint: MV.navy, size: 28)
                Text("Model: \(model.modelName)")
                    .font(.callout).foregroundStyle(MV.ink)
            }
        } header: {
            sectionHeader("How readings are worked out", icon: "brain.head.profile")
        }
        .listRowBackground(MV.surface)
    }

    // MARK: Measurement (source + camera scan style)

    private var measurementSection: some View {
        Section {
            Picker(selection: Binding(
                get: { model.sourceKind },
                set: { model.selectSource($0) }
            )) {
                ForEach(MeasurementSource.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            } label: {
                Text("Measure with")
            }

            if model.sourceKind == .camera {
                Picker(selection: Binding(
                    get: { model.scanMode },
                    set: { model.selectScanMode($0) }
                )) {
                    ForEach(ScanMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                } label: {
                    Text("Camera scan")
                }
                .pickerStyle(.segmented)
                Text(model.scanMode == .palm
                     ? "Hold your palm a few centimetres over the rear camera — no need to touch it."
                     : "Rest a fingertip gently over the rear camera and flash.")
                    .font(.caption2).foregroundStyle(MV.inkMuted)
            } else {
                Button { showPairing = true } label: {
                    Label("Pair wearable…", systemImage: "sensor.tag.radiowaves.forward.fill")
                }
                Text("Wearable mode streams your pulse from a paired MoniVitals device over Bluetooth.")
                    .font(.caption2).foregroundStyle(MV.inkMuted)
            }
        } header: {
            sectionHeader("Measurement", icon: "waveform.path.ecg")
        }
        .listRowBackground(MV.surface)
        .sheet(isPresented: $showPairing) { DevicePairingView() }
    }

    private var movementSection: some View {
        Section {
            Stepper(value: Binding(
                get: { model.settings.motionThresh },
                set: { v in model.updateSettings { $0.motionThresh = v } }
            ), in: 10...80, step: 5) {
                LabeledContent("Movement sensitivity",
                               value: "\(Int(model.settings.motionThresh))")
            }
            Text("Lower means MoniVitals is fussier about holding still before it trusts a reading.")
                .font(.caption2).foregroundStyle(MV.inkMuted)
        } header: {
            sectionHeader("Steadiness", icon: "hand.raised")
        }
        .listRowBackground(MV.surface)
    }

    private var appearanceSection: some View {
        Section {
            // Theme picker removed: the app renders light-only (no dark palette), so
            // a System/Light/Dark control did nothing. Units kept as information.
            LabeledContent("Units", value: "bpm · br/min · ms")
        } header: {
            sectionHeader("Appearance", icon: "paintbrush")
        }
        .listRowBackground(MV.surface)
    }

    // MARK: Account (optional cloud backup)

    private var accountSection: some View {
        Section {
            if model.authState != nil {
                signedInRows
            } else {
                signedOutRows
            }
        } header: {
            sectionHeader("Account", icon: "person.crop.circle")
        }
        .listRowBackground(MV.surface)
    }

    @ViewBuilder
    private var signedOutRows: some View {
        TextField("Email", text: $accountEmail)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("Password", text: $accountPassword)
            .textContentType(.password)
        if let err = accountError {
            Text(err).font(.caption2).foregroundStyle(MV.bad)
        }
        HStack(spacing: MV.s12) {
            Button("Sign in") {
                Task { await runAccountAction { await model.signIn(email: accountEmail, password: accountPassword) } }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Create account") {
                Task { await runAccountAction { await model.createAccount(email: accountEmail, password: accountPassword) } }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .buttonStyle(.borderless) // keep Form from making the whole row tappable
        .disabled(accountBusy || accountEmail.isEmpty || accountPassword.isEmpty)

        // Federated sign-in — a gentler one-tap way in, no password to remember.
        Text("or continue with")
            .font(.caption2).foregroundStyle(MV.inkMuted)
            .frame(maxWidth: .infinity, alignment: .center)
        Button {
            Task { await runAccountAction { await model.signInWithGoogle() } }
        } label: {
            Label("Continue with Google", systemImage: "globe")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(accountBusy)

        SignInWithAppleButton(.continue) { request in
            // Fresh RAW nonce per attempt; Apple stamps its SHA-256 into the JWT.
            let raw = AppleNonce.makeRaw()
            appleRawNonce = raw
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256Hex(raw)
        } onCompletion: { result in
            // Token exchange + nonce round-trip live in AppleSignIn/AuthService so
            // this matches the Google path; the button only collects the credential.
            Task {
                await runAccountAction {
                    await model.signInWithApple(result: result, rawNonce: appleRawNonce)
                }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: MV.rControl, style: .continuous))
        .disabled(accountBusy)

        if accountBusy {
            HStack(spacing: MV.s8) {
                ProgressView()
                Text("One moment…").font(.caption).foregroundStyle(MV.inkMuted)
            }
        }
        Text("Optional — an account backs up your profiles and your list of saved readings. The readings themselves always stay on your phone.")
            .font(.caption2).foregroundStyle(MV.inkMuted)
    }

    @ViewBuilder
    private var signedInRows: some View {
        HStack(spacing: MV.s12) {
            IconBadge(systemName: "person.crop.circle.badge.checkmark", tint: MV.good, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.authState?.email ?? "")
                    .font(.callout).foregroundStyle(MV.ink)
                syncStatusLine
            }
        }
        if let err = accountError {
            Text(err).font(.caption2).foregroundStyle(MV.bad)
        }
        Button {
            Task { await model.syncNow() }
        } label: {
            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(model.syncStatus == .syncing || accountBusy)
        Button("Sign out") {
            accountError = nil
            model.signOut()
        }
        .disabled(accountBusy)
        Button(role: .destructive) { showDeleteAccountConfirm = true } label: {
            Label("Delete account…", systemImage: "person.crop.circle.badge.xmark")
        }
        .foregroundStyle(MV.bad)
        .disabled(accountBusy)
        .confirmationDialog("This removes your account and everything backed up to the cloud. Data on this phone stays.",
                            isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Haptics.warning()
                Task { await runAccountAction { await model.deleteAccount() } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var syncStatusLine: some View {
        Group {
            switch model.syncStatus {
            case .syncing:
                Text("Syncing…").foregroundStyle(MV.inkMuted)
            case .error(let message):
                Text(message).foregroundStyle(MV.bad)
            case .idle:
                if let date = model.lastSyncAt {
                    Text("Backed up \(Self.relativeTime(date))").foregroundStyle(MV.inkMuted)
                } else {
                    Text("Not backed up yet").foregroundStyle(MV.inkMuted)
                }
            }
        }
        .font(.caption)
    }

    /// "just now" / "2 minutes ago" warm relative stamp for the status line.
    private static func relativeTime(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func runAccountAction(_ action: () async -> String?) async {
        accountBusy = true
        accountError = nil
        let err = await action()
        accountBusy = false
        if let err {
            accountError = err
            Haptics.warning()
        } else {
            accountEmail = ""
            accountPassword = ""
            Haptics.success()
        }
    }

    // MARK: Your Data

    private var dataSection: some View {
        Section {
            LabeledContent("Profiles", value: "\(model.subjects.count)")
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete all local data", systemImage: "trash")
            }
            .foregroundStyle(MV.bad)
            .confirmationDialog(model.authState == nil
                                ? "Remove all profiles, clips, and readings from this phone? This can't be undone."
                                : "Remove all profiles, clips, and readings from this phone and your cloud backup? This can't be undone.",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { model.deleteAllData() }
                Button("Cancel", role: .cancel) {}
            }
            Text("Your saved readings stay on this phone. With an account, your profiles and clip list are backed up privately to your space in the cloud.")
                .font(.caption2).foregroundStyle(MV.inkMuted)
        } header: {
            sectionHeader("Your Data", icon: "internaldrive")
        }
        .listRowBackground(MV.surface)
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var aboutSection: some View {
        Section {
            HStack(alignment: .top, spacing: MV.s12) {
                IconBadge(systemName: "sparkles", tint: MV.accent, size: 28)
                Text("MoniVitals measures your heart rate, breathing rate, and heart-rate variability from your fingertip over the rear camera. Everything is worked out on your phone, and every number is a friendly estimate — it's for curiosity and wellbeing, not a substitute for medical care.")
                    .font(.caption).foregroundStyle(MV.inkMuted)
            }
            Link(destination: URL(string: "https://aranyoing.com/monivitals/privacy")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            Link(destination: URL(string: "https://aranyoing.com/monivitals/terms")!) {
                Label("Terms of Use", systemImage: "doc.text")
            }
            LabeledContent("Version", value: versionString)
        } header: {
            sectionHeader("About", icon: "info.circle")
        }
        .listRowBackground(MV.surface)
    }

    // MARK: helpers

    /// Uniform section header: a small accent icon beside the (system-styled) title.
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MV.accent)
            Text(title)
        }
    }
}
