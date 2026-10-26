//
//  SyncService.swift
//  MoniVitals
//
//  Cloud backup of profiles and saved-measurement metadata over the Firestore
//  REST API (docs/CLOUD_SYNC.md). Raw pulse samples and per-session metrics
//  never leave the device.
//
//  Layout: `users/{uid}/{subjects|sessions}/{docId}` where docId is
//  base64url (no padding) of the record's natural key. Each doc is one JSON blob
//  (`json` string field) plus an `updatedAt` stamp — no per-field typing.
//
//  Merge is a pure function (`SyncMerge.plan`) so it is unit-testable without
//  the network: union by natural key, newer record wins, ties keep local.
//

import Foundation

// MARK: - Doc ids (pure, unit-tested)

/// Deterministic, collision-free, reversible Firestore doc ids:
/// base64url (no padding) of the UTF-8 natural key. Subject codes are
/// user-entered and may contain "/" etc., so they can't be used raw.
enum CloudDocID {
    static func encode(_ key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ docId: String) -> String? {
        var b64 = docId
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Offline-delete tombstones

/// Local record of remote docs deleted while the remote delete may not have
/// landed (offline / transient failure). `syncNow`'s union-merge would otherwise
/// re-pull a session/subject the user already deleted, because the remote copy is
/// still present. Keyed by the record's natural key (session `id` / subject
/// `code`), per collection, persisted in UserDefaults. A tombstone is cleared once
/// the remote delete is confirmed (or the doc is already gone).
enum CloudTombstones {
    private static func defaultsKey(_ collection: String) -> String {
        "monivitals.cloud.tombstones.\(collection)"
    }

    /// The set of tombstoned natural keys for a collection.
    static func keys(for collection: String) -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: defaultsKey(collection)) ?? []
        return Set(arr)
    }

    /// Mark a natural key deleted so it is suppressed from re-pull until the
    /// remote delete is confirmed.
    static func add(_ key: String, collection: String) {
        var s = keys(for: collection)
        guard s.insert(key).inserted else { return }
        UserDefaults.standard.set(Array(s), forKey: defaultsKey(collection))
    }

    /// Clear a tombstone once the remote delete has landed (or the doc is gone).
    static func remove(_ key: String, collection: String) {
        var s = keys(for: collection)
        guard s.remove(key) != nil else { return }
        UserDefaults.standard.set(Array(s), forKey: defaultsKey(collection))
    }

    /// Drop every tombstone (a full local/remote wipe or sign-out makes them moot).
    static func clearAll() {
        for collection in ["subjects", "sessions"] {
            UserDefaults.standard.removeObject(forKey: defaultsKey(collection))
        }
    }
}

// MARK: - Merge planning (pure, unit-tested)

enum SyncMerge {
    /// What one sync pass should do for a collection.
    struct Plan<T> {
        /// Remote records missing locally or newer than the local copy.
        var toLocal: [T] = []
        /// Local records whose remote doc is absent or older.
        var toPush: [T] = []
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseStamp(_ s: String) -> Date? {
        isoPlain.date(from: s) ?? isoFractional.date(from: s)
    }

    /// True when stamp `a` is strictly newer than `b`. Prefers real date
    /// parsing (handles fractional vs. whole seconds across platforms);
    /// falls back to string comparison. Equal → false, so ties keep local.
    static func isNewer(_ a: String, _ b: String) -> Bool {
        if let da = parseStamp(a), let db = parseStamp(b) { return da > db }
        return a > b
    }

    /// Compare two ISO stamp pairs: primary stamp first, then secondary.
    /// Useful for sessions where `endedAt` may be filled after first sync.
    static func compareStamps(primary aPrimary: String, secondary aSecondary: String?,
                              primary bPrimary: String, secondary bSecondary: String?) -> Int {
        if isNewer(aPrimary, bPrimary) { return 1 }
        if isNewer(bPrimary, aPrimary) { return -1 }
        let aSecondary = aSecondary ?? ""
        let bSecondary = bSecondary ?? ""
        if isNewer(aSecondary, bSecondary) { return 1 }
        if isNewer(bSecondary, aSecondary) { return -1 }
        return 0
    }

    /// Drop remote records whose natural key is tombstoned (deleted locally while
    /// offline). Without this the union-merge would re-pull a record the user
    /// already deleted, because the remote delete hadn't landed yet. Pure so the
    /// suppression is unit-testable without the network.
    static func filterTombstoned<T>(_ remote: [T], tombstoned: Set<String>,
                                    key: (T) -> String) -> [T] {
        guard !tombstoned.isEmpty else { return remote }
        return remote.filter { !tombstoned.contains(key($0)) }
    }

    /// Union-merge by natural key: pull remote records that are missing or
    /// newer, push local records that are missing or newer remotely. Records
    /// with equal stamps stay as they are (local wins, nothing pushed).
    static func plan<T>(local: [T], remote: [T],
                        key: (T) -> String, stamp: (T) -> String) -> Plan<T> {
        plan(local: local, remote: remote, key: key) { a, b in
            isNewer(stamp(a), stamp(b)) ? 1 : (isNewer(stamp(b), stamp(a)) ? -1 : 0)
        }
    }

    /// Comparator variant for records whose freshness is not a single stamp.
    static func plan<T>(local: [T], remote: [T],
                        key: (T) -> String, compare: (T, T) -> Int) -> Plan<T> {
        let pickNewer: (T, T) -> T = { compare($1, $0) > 0 ? $1 : $0 }
        let localByKey = Dictionary(local.map { (key($0), $0) }, uniquingKeysWith: pickNewer)
        let remoteByKey = Dictionary(remote.map { (key($0), $0) }, uniquingKeysWith: pickNewer)

        var plan = Plan<T>()
        for (k, r) in remoteByKey {
            if let l = localByKey[k] {
                if compare(r, l) > 0 { plan.toLocal.append(r) }
            } else {
                plan.toLocal.append(r)
            }
        }
        for (k, l) in localByKey {
            if let r = remoteByKey[k] {
                if compare(l, r) > 0 { plan.toPush.append(l) }
            } else {
                plan.toPush.append(l)
            }
        }
        return plan
    }
}

// MARK: - Sync status (surfaced in Settings)

enum CloudSyncStatus: Equatable {
    case idle
    case syncing
    /// Warm copy ready to show inline.
    case error(String)
}

// MARK: - Firestore REST client

private enum FirestoreREST {
    static let base =
        "https://firestore.googleapis.com/v1/projects/monivitals/databases/(default)/documents"

    struct RemoteDoc {
        let docId: String
        let json: String
        let updatedAt: String
    }

    private struct ListResponse: Decodable {
        struct StringValue: Decodable { let stringValue: String? }
        struct Fields: Decodable {
            let json: StringValue?
            let updatedAt: StringValue?
        }
        struct Doc: Decodable {
            let name: String
            let fields: Fields?
        }
        let documents: [Doc]?
        let nextPageToken: String?
    }

    private static func docURL(uid: String, collection: String, docId: String) -> URL? {
        URL(string: "\(base)/users/\(uid)/\(collection)/\(docId)")
    }

    private static func request(_ url: URL, method: String, idToken: String,
                                body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        await req.attachAppCheck()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        return data
    }

    /// PATCH-upsert one record blob.
    static func upsert(uid: String, collection: String, docId: String,
                       json: String, idToken: String) async throws {
        guard let url = docURL(uid: uid, collection: collection, docId: docId) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        // Fractional seconds so two writes in the same wall-clock second don't tie
        // (a tie stalls a legitimate remote-newer pull in the merge).
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = fmt.string(from: Date())
        let payload: [String: Any] = ["fields": [
            "json": ["stringValue": json],
            "updatedAt": ["stringValue": now],
        ]]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        _ = try await request(url, method: "PATCH", idToken: idToken, body: body)
    }

    /// List every doc in a collection, following pagination. A collection that
    /// was never written returns `{}` (no `documents` key) → empty list.
    static func list(uid: String, collection: String,
                     idToken: String) async throws -> [RemoteDoc] {
        var out: [RemoteDoc] = []
        var pageToken: String?
        repeat {
            var urlString = "\(base)/users/\(uid)/\(collection)?pageSize=300"
            if let t = pageToken,
               let esc = t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                urlString += "&pageToken=\(esc)"
            }
            guard let url = URL(string: urlString) else {
                throw CloudError.friendly(AuthService.offlineMessage)
            }
            let data = try await request(url, method: "GET", idToken: idToken)
            let page = (try? JSONDecoder().decode(ListResponse.self, from: data))
                ?? ListResponse(documents: nil, nextPageToken: nil)
            for doc in page.documents ?? [] {
                guard let json = doc.fields?.json?.stringValue else { continue }
                let docId = doc.name.components(separatedBy: "/").last ?? doc.name
                out.append(RemoteDoc(docId: docId, json: json,
                                     updatedAt: doc.fields?.updatedAt?.stringValue ?? ""))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    static func delete(uid: String, collection: String, docId: String,
                       idToken: String) async throws {
        guard let url = docURL(uid: uid, collection: collection, docId: docId) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        _ = try await request(url, method: "DELETE", idToken: idToken)
    }
}

// MARK: - Sync service

/// Serialized cloud sync + remote-delete hooks. An actor so two syncs can
/// never overlap; network always runs off the main actor.
actor SyncService {
    static let shared = SyncService()

    private let store: Store
    private var running = false
    private static let lastSyncKey = "monivitals.cloud.lastSyncAt"

    init(store: Store = .shared) {
        self.store = store
    }

    /// Result of a completed sync: the (possibly refreshed) auth state and
    /// when it finished.
    struct Outcome {
        var state: AuthState
        var syncedAt: Date
    }

    // MARK: Last-sync timestamp (persisted alongside auth state)

    static func loadLastSync() -> Date? {
        let t = UserDefaults.standard.double(forKey: lastSyncKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func clearLastSync() {
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        // Sign-out clears the sync marker; drop tombstones too so a different account
        // signed in on this device never inherits this account's deleted-doc set.
        CloudTombstones.clearAll()
    }

    private static func persistLastSync(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSyncKey)
    }

    // MARK: Full sync

    /// Pull-merge-push all three collections. Returns nil when a sync was
    /// already running (this pass was skipped). Throws `CloudError` with warm
    /// copy on trouble; `.signedOut` when the refresh token was revoked.
    func syncNow(state: AuthState) async throws -> Outcome? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        let fresh = try await AuthService.freshState(state)
        let decoder = JSONDecoder()

        // Subjects — natural key `code`, stamp `createdAt`.
        let subjectDocs = try await FirestoreREST.list(
            uid: fresh.uid, collection: "subjects", idToken: fresh.idToken)
        let allRemoteSubjects = subjectDocs.compactMap {
            try? decoder.decode(Subject.self, from: Data($0.json.utf8))
        }
        // Suppress any subject the user deleted while offline from being re-pulled,
        // and retry its remote delete so the tombstone can eventually clear. Derive
        // "present" from the RAW remote doc ids (not the decoded records) so a doc
        // still in Firestore but currently undecodable (schema drift) keeps its
        // tombstone instead of having it cleared and being re-pulled later.
        let presentSubjects = Set(subjectDocs.compactMap { CloudDocID.decode($0.docId) })
        let subjectTombstones = CloudTombstones.keys(for: "subjects")
        await reconcileTombstones(subjectTombstones, present: presentSubjects,
                                  collection: "subjects", state: fresh)
        let remoteSubjects = SyncMerge.filterTombstoned(allRemoteSubjects,
                                                        tombstoned: subjectTombstones,
                                                        key: { $0.code })
        let subjectPlan = SyncMerge.plan(local: store.listSubjects(),
                                         remote: remoteSubjects,
                                         key: { $0.code }, stamp: { $0.createdAt })
        for s in subjectPlan.toLocal { store.upsertSubject(s) }
        for s in subjectPlan.toPush {
            try await push(s, key: s.code, collection: "subjects", state: fresh)
        }

        // Sessions (metadata only) — natural key `id`, stamp `startedAt`, then `endedAt`.
        let sessionDocs = try await FirestoreREST.list(
            uid: fresh.uid, collection: "sessions", idToken: fresh.idToken)
        let allRemoteSessions = sessionDocs.compactMap {
            try? decoder.decode(Session.self, from: Data($0.json.utf8))
        }
        // "Present" comes from the RAW remote doc ids so a present-but-undecodable
        // session doc keeps its tombstone (see the subjects note above).
        let presentSessions = Set(sessionDocs.compactMap { CloudDocID.decode($0.docId) })
        let sessionTombstones = CloudTombstones.keys(for: "sessions")
        await reconcileTombstones(sessionTombstones, present: presentSessions,
                                  collection: "sessions", state: fresh)
        let remoteSessions = SyncMerge.filterTombstoned(allRemoteSessions,
                                                        tombstoned: sessionTombstones,
                                                        key: { $0.id })
        let sessionPlan = SyncMerge.plan(local: store.listSessions(),
                                         remote: remoteSessions,
                                         key: { $0.id },
                                         compare: { a, b in
                                             SyncMerge.compareStamps(primary: a.startedAt, secondary: a.endedAt,
                                                                     primary: b.startedAt, secondary: b.endedAt)
                                         })
        for s in sessionPlan.toLocal { store.createSession(s) }
        for s in sessionPlan.toPush {
            try await push(s, key: s.id, collection: "sessions", state: fresh)
        }

        let now = Date()
        Self.persistLastSync(now)
        return Outcome(state: fresh, syncedAt: now)
    }

    private func push<T: Encodable>(_ record: T, key: String, collection: String,
                                    state: AuthState) async throws {
        guard let data = try? JSONEncoder().encode(record),
              let json = String(data: data, encoding: .utf8) else { return }
        try await FirestoreREST.upsert(uid: state.uid, collection: collection,
                                       docId: CloudDocID.encode(key), json: json,
                                       idToken: state.idToken)
    }

    /// During a sync, for each tombstoned key: if the doc is no longer present
    /// remotely the delete already landed → clear the tombstone; if it is still
    /// present, retry the remote delete and clear the tombstone on success. Keys
    /// that stay present (delete failed again) keep their tombstone so re-pull stays
    /// suppressed until the next pass.
    private func reconcileTombstones(_ tombstones: Set<String>, present: Set<String>,
                                     collection: String, state: AuthState) async {
        for key in tombstones {
            if !present.contains(key) {
                CloudTombstones.remove(key, collection: collection)
                continue
            }
            do {
                try await FirestoreREST.delete(uid: state.uid, collection: collection,
                                               docId: CloudDocID.encode(key),
                                               idToken: state.idToken)
                CloudTombstones.remove(key, collection: collection)
            } catch {
                // Still couldn't delete — keep the tombstone so the merge below
                // continues to suppress this doc.
            }
        }
    }

    // MARK: Remote-delete hooks (best effort). A local tombstone suppresses the doc
    // from being re-pulled by the merge until the remote delete is confirmed (see
    // `reconcileTombstones` + `CloudTombstones`), so an offline delete can't bring a
    // cloud copy back on the next sync.

    func deleteSessionRemote(id: String, state: AuthState) async {
        // Tombstone first: if the network delete below fails (offline / transient),
        // the next sync still won't re-pull this session.
        CloudTombstones.add(id, collection: "sessions")
        guard let fresh = try? await AuthService.freshState(state) else { return }
        do {
            try await FirestoreREST.delete(uid: fresh.uid, collection: "sessions",
                                           docId: CloudDocID.encode(id),
                                           idToken: fresh.idToken)
            CloudTombstones.remove(id, collection: "sessions")
        } catch {
            // Leave the tombstone; a later sync retries via reconcileTombstones.
        }
    }

    /// Remove a subject's doc plus its remote sessions.
    func deleteSubjectRemote(code: String, state: AuthState) async {
        CloudTombstones.add(code, collection: "subjects")
        guard let fresh = try? await AuthService.freshState(state) else { return }
        var subjectDeleted = false
        do {
            try await FirestoreREST.delete(uid: fresh.uid, collection: "subjects",
                                           docId: CloudDocID.encode(code),
                                           idToken: fresh.idToken)
            subjectDeleted = true
        } catch {
            // Keep the subject tombstone; a later sync retries it.
        }
        if subjectDeleted { CloudTombstones.remove(code, collection: "subjects") }
        let decoder = JSONDecoder()
        if let docs = try? await FirestoreREST.list(uid: fresh.uid,
                                                    collection: "sessions",
                                                    idToken: fresh.idToken) {
            for doc in docs {
                guard let s = try? decoder.decode(Session.self, from: Data(doc.json.utf8)),
                      s.subjectCode == code else { continue }
                // Tombstone each of the subject's sessions too so a failed session
                // delete isn't re-pulled either.
                CloudTombstones.add(s.id, collection: "sessions")
                do {
                    try await FirestoreREST.delete(uid: fresh.uid, collection: "sessions",
                                                   docId: doc.docId, idToken: fresh.idToken)
                    CloudTombstones.remove(s.id, collection: "sessions")
                } catch {
                    // Leave the session tombstone for the next sync.
                }
            }
        }
    }

    /// Wipe everything under `users/{uid}` (best-effort loop over the
    /// collections). Used by "Delete all data" while signed in and before
    /// account deletion.
    func deleteAllRemote(state: AuthState) async {
        // Everything is going away, so any outstanding per-doc tombstones are moot.
        CloudTombstones.clearAll()
        guard let fresh = try? await AuthService.freshState(state) else { return }
        for collection in ["subjects", "sessions"] {
            guard let docs = try? await FirestoreREST.list(uid: fresh.uid,
                                                           collection: collection,
                                                           idToken: fresh.idToken)
            else { continue }
            for doc in docs {
                try? await FirestoreREST.delete(uid: fresh.uid, collection: collection,
                                                docId: doc.docId, idToken: fresh.idToken)
            }
        }
    }

    // MARK: Account deletion

    /// Best-effort wipe of the user's cloud docs, then delete the Firebase
    /// account itself. The caller signs out locally afterwards.
    func deleteAccount(state: AuthState) async throws {
        let fresh = try await AuthService.freshState(state)
        await deleteAllRemote(state: fresh)
        // Verify the wipe actually drained BEFORE deleting the account — otherwise a
        // partial failure orphans docs under a uid that can no longer authenticate,
        // while the user is told deletion succeeded.
        for collection in ["subjects", "sessions"] {
            if let remaining = try? await FirestoreREST.list(uid: fresh.uid,
                                                             collection: collection,
                                                             idToken: fresh.idToken),
               !remaining.isEmpty {
                // CloudError so the warm copy actually reaches the user — a plain
                // NSError would be flattened to the generic offline message.
                throw CloudError.friendly(
                    "Couldn't remove all your cloud data — check your connection and try again.")
            }
        }
        try await AuthService.deleteAccount(idToken: fresh.idToken)
    }
}
