//
//  CloudSyncTests.swift
//  MoniVitalsTests
//
//  Pure-function coverage for the cloud layer (docs/CLOUD_SYNC.md): doc-id
//  round-trips, merge planning, and auth error copy. No network involved.
//

import XCTest
@testable import MoniVitals

final class CloudSyncTests: XCTestCase {
    // MARK: - base64url doc ids

    func testDocIdRoundTripSimple() {
        let key = "S-001"
        XCTAssertEqual(CloudDocID.decode(CloudDocID.encode(key)), key)
    }

    func testDocIdRoundTripSlashPlusAndPadding() {
        // Keys chosen so plain base64 would contain '/', '+' and '=' — the
        // url-safe form must not, and must still round-trip exactly.
        for key in ["a/b/c", "subj?~~", "x", "xy", "xyz", "code#2024-01-02T03:04:05Z"] {
            let docId = CloudDocID.encode(key)
            XCTAssertFalse(docId.contains("/"), "docId must be path-safe: \(docId)")
            XCTAssertFalse(docId.contains("+"), "docId must be url-safe: \(docId)")
            XCTAssertFalse(docId.contains("="), "docId must be unpadded: \(docId)")
            XCTAssertEqual(CloudDocID.decode(docId), key)
        }
    }

    func testDocIdRoundTripUnicode() {
        let key = "sujet-éà-🐘/मेरा"
        XCTAssertEqual(CloudDocID.decode(CloudDocID.encode(key)), key)
    }

    func testDocIdDeterministic() {
        XCTAssertEqual(CloudDocID.encode("same"), CloudDocID.encode("same"))
    }

    // MARK: - merge planning

    private struct Rec: Equatable {
        let k: String
        let stamp: String
        let tag: String
    }

    private func plan(local: [Rec], remote: [Rec]) -> SyncMerge.Plan<Rec> {
        SyncMerge.plan(local: local, remote: remote, key: { $0.k }, stamp: { $0.stamp })
    }

    func testMergeUnionOfDisjointSets() {
        let l = Rec(k: "a", stamp: "2024-01-01T00:00:00Z", tag: "local")
        let r = Rec(k: "b", stamp: "2024-01-02T00:00:00Z", tag: "remote")
        let p = plan(local: [l], remote: [r])
        XCTAssertEqual(p.toLocal, [r])
        XCTAssertEqual(p.toPush, [l])
    }

    func testMergeNewerRemoteWins() {
        let l = Rec(k: "a", stamp: "2024-01-01T00:00:00Z", tag: "old-local")
        let r = Rec(k: "a", stamp: "2024-06-01T00:00:00Z", tag: "new-remote")
        let p = plan(local: [l], remote: [r])
        XCTAssertEqual(p.toLocal, [r])
        XCTAssertTrue(p.toPush.isEmpty)
    }

    func testMergeNewerLocalPushed() {
        let l = Rec(k: "a", stamp: "2024-06-01T00:00:00Z", tag: "new-local")
        let r = Rec(k: "a", stamp: "2024-01-01T00:00:00Z", tag: "old-remote")
        let p = plan(local: [l], remote: [r])
        XCTAssertTrue(p.toLocal.isEmpty)
        XCTAssertEqual(p.toPush, [l])
    }

    func testMergeEqualStampsKeepLocalAndPushNothing() {
        let l = Rec(k: "a", stamp: "2024-01-01T00:00:00Z", tag: "local")
        let r = Rec(k: "a", stamp: "2024-01-01T00:00:00Z", tag: "remote")
        let p = plan(local: [l], remote: [r])
        XCTAssertTrue(p.toLocal.isEmpty)
        XCTAssertTrue(p.toPush.isEmpty)
    }

    func testIsNewerHandlesFractionalSeconds() {
        // Lexicographic comparison would get this backwards ('.' < 'Z').
        XCTAssertTrue(SyncMerge.isNewer("2024-01-01T00:00:00.500Z", "2024-01-01T00:00:00Z"))
        XCTAssertFalse(SyncMerge.isNewer("2024-01-01T00:00:00Z", "2024-01-01T00:00:00.500Z"))
        XCTAssertFalse(SyncMerge.isNewer("2024-01-01T00:00:00Z", "2024-01-01T00:00:00Z"))
    }

    private struct Sess: Equatable {
        let id: String
        let startedAt: String
        let endedAt: String?
        let tag: String
    }

    private func sessionPlan(local: [Sess], remote: [Sess]) -> SyncMerge.Plan<Sess> {
        SyncMerge.plan(local: local, remote: remote, key: { $0.id }) { a, b in
            SyncMerge.compareStamps(primary: a.startedAt, secondary: a.endedAt,
                                    primary: b.startedAt, secondary: b.endedAt)
        }
    }

    func testSessionEndedAtSetAfterFirstPushRePushes() {
        let l = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: "2026-01-01T00:05:00Z", tag: "local-closed")
        let r = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: nil, tag: "remote-open")
        let p = sessionPlan(local: [l], remote: [r])
        XCTAssertTrue(p.toLocal.isEmpty)
        XCTAssertEqual(p.toPush, [l])
    }

    func testSessionRemoteClosedCopyWinsOverLocalOpenCopy() {
        let l = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: nil, tag: "local-open")
        let r = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: "2026-01-01T00:05:00Z", tag: "remote-closed")
        let p = sessionPlan(local: [l], remote: [r])
        XCTAssertEqual(p.toLocal, [r])
        XCTAssertTrue(p.toPush.isEmpty)
    }

    func testSessionLaterEndedAtWinsTieBreak() {
        let l = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: "2026-01-01T00:09:00Z", tag: "local-later-end")
        let r = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: "2026-01-01T00:05:00Z", tag: "remote-earlier-end")
        let p = sessionPlan(local: [l], remote: [r])
        XCTAssertTrue(p.toLocal.isEmpty)
        XCTAssertEqual(p.toPush, [l])
    }

    func testSessionEqualStartedAndEndedKeepsLocalAndPushesNothing() {
        let l = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: "2026-01-01T00:05:00Z", tag: "local")
        let r = Sess(id: "s1", startedAt: "2026-01-01T00:00:00Z",
                     endedAt: "2026-01-01T00:05:00Z", tag: "remote")
        let p = sessionPlan(local: [l], remote: [r])
        XCTAssertTrue(p.toLocal.isEmpty)
        XCTAssertTrue(p.toPush.isEmpty)
    }

    // MARK: - offline-delete tombstones

    func testTombstoneSuppressesRePullOfDeletedRemote() {
        // A session deleted locally while offline is still present remotely; the
        // merge must not re-pull it.
        let deleted = Rec(k: "s1", stamp: "2024-01-01T00:00:00Z", tag: "deleted-remote")
        let kept = Rec(k: "s2", stamp: "2024-01-02T00:00:00Z", tag: "kept-remote")
        let filtered = SyncMerge.filterTombstoned([deleted, kept],
                                                  tombstoned: ["s1"], key: { $0.k })
        XCTAssertEqual(filtered, [kept])
        // And the union-merge over the filtered remote never plans a pull for s1.
        let p = plan(local: [], remote: filtered)
        XCTAssertEqual(p.toLocal, [kept])
        XCTAssertFalse(p.toLocal.contains { $0.k == "s1" })
    }

    func testEmptyTombstonesLeaveRemoteUntouched() {
        let a = Rec(k: "a", stamp: "2024-01-01T00:00:00Z", tag: "a")
        let b = Rec(k: "b", stamp: "2024-01-02T00:00:00Z", tag: "b")
        XCTAssertEqual(SyncMerge.filterTombstoned([a, b], tombstoned: [], key: { $0.k }), [a, b])
    }

    func testTombstoneStoreAddKeysRemoveRoundTrip() {
        let collection = "sessions.test.\(UUID().uuidString)"
        // Isolate this test's keys so it can't collide with real app state.
        defer { UserDefaults.standard.removeObject(forKey: "monivitals.cloud.tombstones.\(collection)") }
        XCTAssertTrue(CloudTombstones.keys(for: collection).isEmpty)
        CloudTombstones.add("s1", collection: collection)
        CloudTombstones.add("s2", collection: collection)
        CloudTombstones.add("s1", collection: collection)   // idempotent
        XCTAssertEqual(CloudTombstones.keys(for: collection), ["s1", "s2"])
        CloudTombstones.remove("s1", collection: collection)
        XCTAssertEqual(CloudTombstones.keys(for: collection), ["s2"])
    }

    // MARK: - auth error copy

    func testFriendlyAuthMessagesMatchSpec() {
        XCTAssertEqual(AuthService.friendlyAuthMessage("EMAIL_EXISTS"),
                       "That email already has an account — try signing in instead.")
        let mismatch = "That email and password don't match — have another look and try again."
        XCTAssertEqual(AuthService.friendlyAuthMessage("INVALID_LOGIN_CREDENTIALS"), mismatch)
        XCTAssertEqual(AuthService.friendlyAuthMessage("INVALID_PASSWORD"), mismatch)
        XCTAssertEqual(AuthService.friendlyAuthMessage("EMAIL_NOT_FOUND"), mismatch)
        XCTAssertEqual(AuthService.friendlyAuthMessage("INVALID_EMAIL"),
                       "That doesn't look like an email address yet.")
        XCTAssertEqual(AuthService.friendlyAuthMessage("CONFIGURATION_NOT_FOUND"),
                       "Cloud accounts aren't switched on for this build yet.")
    }

    func testFriendlyAuthMessageMatchesPrefixes() {
        XCTAssertEqual(
            AuthService.friendlyAuthMessage("WEAK_PASSWORD : Password should be at least 6 characters"),
            "Passwords need at least 6 characters.")
        XCTAssertEqual(
            AuthService.friendlyAuthMessage("TOO_MANY_ATTEMPTS_TRY_LATER : Try again later."),
            "Lots of tries in a row — take a short break and try again.")
    }

    func testFriendlyAuthMessageFallsBackToOfflineCopy() {
        let offline = "Couldn't reach the cloud right now — your data is safe on this device."
        XCTAssertEqual(AuthService.friendlyAuthMessage(nil), offline)
        XCTAssertEqual(AuthService.friendlyAuthMessage(""), offline)
        XCTAssertEqual(AuthService.friendlyAuthMessage("SOMETHING_NEW"), offline)
    }
}
