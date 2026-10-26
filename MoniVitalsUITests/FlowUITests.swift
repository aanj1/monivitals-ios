//
//  FlowUITests.swift
//  MoniVitalsUITests
//
//  End-to-end runtime verification: drives every screen of the MoniVitals app,
//  clears the first-run welcome gate, and visits each tab (Home, Measure, Clips,
//  Settings), capturing a full-screen screenshot of each.
//
//  There is no camera in the Simulator, so the app settles into the friendly
//  "needs a real iPhone camera" / guidance state rather than producing a live
//  heart rate — the flow asserts the app renders those states without crashing.
//

import XCTest

final class FlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Helpers

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Clear the first-run welcome gate if it's showing (a toggle + "Get started").
    private func clearOnboardingIfPresent() {
        let getStarted = app.buttons["Get started"]
        let welcome = app.staticTexts["Welcome to MoniVitals"]
        let gateShown = getStarted.waitForExistence(timeout: 8)
            || welcome.waitForExistence(timeout: 2)
        guard gateShown else { return }

        snap("00-Onboarding")

        // "Get started" is always enabled now (tapping it is the acknowledgement).
        if getStarted.waitForExistence(timeout: 3), getStarted.isHittable {
            getStarted.tap()
        }
    }

    /// Open a tab by its tab-bar label, retrying briefly across transitions.
    @discardableResult
    private func openTab(_ label: String) -> Bool {
        let direct = app.tabBars.buttons[label]
        for _ in 0..<6 {
            if direct.waitForExistence(timeout: 3) && direct.isHittable {
                direct.tap()
                return true
            }
            usleep(400_000)
        }
        return false
    }

    /// Open a tab and confirm a distinctive element appeared, self-healing against
    /// transition races.
    @discardableResult
    private func visit(_ tab: String, navBar: String, texts: [String]) -> Bool {
        for _ in 0..<3 {
            _ = openTab(tab)
            if app.navigationBars[navBar].waitForExistence(timeout: 4) { return true }
            for t in texts where app.staticTexts[t].waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    // MARK: - one big flow

    func testDriveEveryScreen() throws {
        // 1) Welcome gate.
        clearOnboardingIfPresent()

        // 2) Tab bar should now be present.
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 8)

        // Home — nav title "MoniVitals". The camera only opens on the Measure
        // screen, so Home shows the idle "take a reading" state after onboarding.
        let dashHeader = app.staticTexts["MoniVitals"].firstMatch
        XCTAssertTrue(dashHeader.waitForExistence(timeout: 10),
                      "Home header 'MoniVitals' should appear after onboarding")
        let idleCopy = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Measure tab'")).firstMatch
        XCTAssertTrue(idleCopy.waitForExistence(timeout: 8),
                      "Home should invite the user to the Measure tab")
        snap("01-Home")

        // Measure — nav title "Measure"; friendly "needs a real iPhone camera" state.
        XCTAssertTrue(
            visit("Measure", navBar: "Measure",
                  texts: ["This needs a real iPhone camera", "Getting the camera ready…"]),
            "Measure screen distinctive element not found")
        snap("02-Measure")

        // Clips — nav title "Saved Clips"; empty state "No saved clips yet".
        XCTAssertTrue(
            visit("Clips", navBar: "Saved Clips",
                  texts: ["No saved clips yet", "Saved clips"]),
            "Clips screen distinctive element not found")
        snap("03-Clips")

        // Settings — nav title "Settings"; "About" section.
        XCTAssertTrue(
            visit("Settings", navBar: "Settings", texts: ["About"]),
            "Settings screen distinctive element not found")
        snap("04-Settings")
    }

    /// Drive the MoniVitals device path: switch the source to "MoniVitals device"
    /// on Home, then open pairing. The Simulator has no BLE radio, so the source
    /// settles into the friendly "Bluetooth isn't available here" state — the test
    /// asserts the picker + pairing screen render without crashing and screenshots
    /// both. This is the runtime proof the BLE UI is wired up.
    func testDevicePairingScreen() throws {
        clearOnboardingIfPresent()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 8)

        // Home shows the source picker; pick the wearable device source.
        let devicePicker = app.buttons["Wearable device"].firstMatch
        XCTAssertTrue(devicePicker.waitForExistence(timeout: 10),
                      "Source picker 'Wearable device' should appear on Home")
        devicePicker.tap()
        snap("07-Home-device-source")

        // Tapping the device source opens the pairing sheet. On a real device with
        // BLE off / in the Simulator this shows the friendly unavailable state.
        let pairingTitle = app.staticTexts["MoniVitals device"].firstMatch
        _ = pairingTitle.waitForExistence(timeout: 6)
        let unavailable = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Bluetooth'")).firstMatch
        let nearby = app.staticTexts["Nearby devices"].firstMatch
        let anyPairingState = unavailable.waitForExistence(timeout: 8)
            || nearby.waitForExistence(timeout: 2)
            || app.staticTexts["Connect your MoniVitals device"].firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(anyPairingState,
                      "Pairing screen should render a state (unavailable / scanning / list)")
        snap("08-Pairing")
    }

    /// End-to-end sign-in against the live Firebase backend. The test account is
    /// created + torn down out-of-band (see the shell harness that runs this); here
    /// we only drive the UI: enter the credentials passed via launch environment,
    /// tap "Sign in", and assert the signed-in state appears ("Sign out" button).
    func testSignInFlow() throws {
        // Fixed credentials for a throwaway account the shell harness creates via
        // Firebase REST before this test and deletes after. Hitting the live
        // backend proves the Account UI → AuthService → signed-in wiring end to end.
        let email = "uitest@monivitals.app"
        let password = "MoniTest!2026"

        clearOnboardingIfPresent()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 8)

        XCTAssertTrue(visit("Settings", navBar: "Settings", texts: ["About"]),
                      "Settings not reachable")

        // The settings form grew (Measurement section sits above Account), and
        // SwiftUI Form rows don't exist in the accessibility hierarchy until
        // scrolled on-screen — scroll until the account form materializes.
        for _ in 0..<4 where !app.textFields["Email"].exists && !app.buttons["Sign out"].exists {
            app.swipeUp()
        }

        // The Simulator keychain survives app reinstalls, so a prior run may leave
        // us signed in. If so, sign out first (this also exercises sign-out) to get
        // back to the signed-out form.
        let existingSignOut = app.buttons["Sign out"]
        if existingSignOut.waitForExistence(timeout: 3) {
            existingSignOut.tap()
            XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 6),
                          "Signed-out form did not return after sign out")
        }

        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 6), "Email field missing")
        emailField.tap()
        emailField.typeText(email)

        let pwField = app.secureTextFields["Password"]
        XCTAssertTrue(pwField.waitForExistence(timeout: 4), "Password field missing")
        pwField.tap()
        pwField.typeText(password)

        snap("05-Account-filled")

        // Self-provisioning so the test needs no external account setup: try to sign
        // in; if the account doesn't exist yet, create it. Either path lands on the
        // signed-in state ("Sign out" button).
        let signOut = app.buttons["Sign out"]
        let signIn = app.buttons["Sign in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 4) && signIn.isHittable, "Sign in button missing")
        signIn.tap()

        if !signOut.waitForExistence(timeout: 12) {
            // Sign-in didn't take (likely no such account) → create it, then retry.
            let create = app.buttons["Create account"]
            if create.waitForExistence(timeout: 3), create.isHittable {
                create.tap()
            }
            if !signOut.waitForExistence(timeout: 12), signIn.isHittable {
                signIn.tap()
            }
        }

        XCTAssertTrue(signOut.waitForExistence(timeout: 15),
                      "Signed-in state ('Sign out') did not appear — auth failed")
        snap("06-Signed-in")
    }
}
