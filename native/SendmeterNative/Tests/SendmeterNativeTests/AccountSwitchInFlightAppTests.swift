import SwiftUI
import UIKit
import XCTest

@_spi(Experimental) import Auth
import SendmeterCore
import SendmeterWeather
import Supabase

@testable import Sendmeter

/// #933: in-flight refresh and save isolation across account switches.
///
/// These tests drive a REAL signed-in `AppModel` through its production auth
/// boundary (`AppModel.signIn` / `AppModel.signOut` -> the Supabase SDK's
/// `authStateChanges` -> `handleAuthEvent` -> `resetAccountState` -> the
/// bootstrap refresh), suspending real repository requests inside the
/// URLSession transport and releasing them only after the account changed.
///
/// The account boundary is the real one: the SDK's stored session is the only
/// credential source (`PostgRESTClient(sessionProvider:)` reads the live
/// session through `AuthService.ensureFreshSession()`, exactly as
/// `AppModel.init` wires it), so a request that escaped the fence after a
/// switch would automatically carry the NEW account's bearer token — which
/// several of these tests assert cannot happen.
///
/// Every substitution is a seam the production code already exposes and the
/// other app-target suites already use: a URLSession protocol stub (no live
/// backend), an in-memory `AuthLocalStorage`, a file-backed
/// `LocalCacheStore` the test seeds, `ServerClockStore`/`AuthSessionGuardStore`
/// on a private `UserDefaults` suite, and `CacheStorageSeams`. No live
/// Supabase, no HealthKit, no secret material, and no source-text proxy.
@MainActor
final class AccountSwitchInFlightAppTests: XCTestCase {
    private let accountA = UUID()
    private let accountB = UUID()

    // MARK: - AC1: A -> B, late success

    /// The refresh funnel's publication closure (`AppModel.refreshAll` ->
    /// `publishIfCurrent` -> `mergeSessions`) is what puts rows on screen. A
    /// pass suspended across an account switch must return before it, so none
    /// of A's rows may enter B's history.
    func testLateSuccessAfterAnAccountSwitchNeverPublishesTheOldAccountsData() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        // A's own bootstrap already published A's seeded cache row.
        XCTAssertEqual(model.sessions.map(\.id), [harness.seededSessionID])
        XCTAssertEqual(model.currentUserID, accountA)

        let held = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let pass = Task { await model.refreshAll() }
        await expectEntry(held, "A's sessions delta must reach the transport", server: server)
        XCTAssertTrue(model.isRefreshing, "A's own pass owns the spinner while it is suspended")

        try await signIn(as: accountB, in: harness)
        XCTAssertEqual(model.sessions, [], "B's bootstrap must publish B's (empty) history")

        // Release A's response into a context it no longer owns.
        held.release(status: 200, body: sessionRowJSON(id: harness.lateRowID, note: "late A row"))
        await pass.value
        try await waitForQuietLog(server)

        XCTAssertEqual(
            model.sessions,
            [],
            "a suspended A pass must not merge A's rows into B's history"
        )
        XCTAssertFalse(model.isRefreshing, "B's settled pass released its own spinner")
        XCTAssertEqual(model.currentUserID, accountB)
    }

    // MARK: - AC1: A -> B, late auth rejection

    /// A rejected bearer from the OLD account must not surface a banner on the
    /// new account and must not sign the new account out. Two independent
    /// fences are exercised: `recordPartialRefresh`'s
    /// `AccountScopedFetch.canApply` publication guard (the failure summary and
    /// the Dashboard class), and `AuthService.recoverFromAuthFailure`'s
    /// exact-session self-heal (`PostgRESTError.sessionDescriptor` is A's
    /// session while the live session is B's, so nothing is cleared).
    func testLateAuthRejectionAfterAnAccountSwitchNeverSignsTheNewAccountOut() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        let held = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let pass = Task { await model.refreshAll() }
        await expectEntry(held, "the session request reached the transport", server: server)

        try await signIn(as: accountB, in: harness)
        XCTAssertEqual(model.currentUserID, accountB)
        // The banner is a shared surface other bootstrap steps can legitimately
        // touch; the claim here is that the stale 401 does not CHANGE it.
        let bannerBeforeRelease = model.errorMessage

        held.release(status: 401, body: Data(#"{"message":"JWT expired"}"#.utf8))
        await pass.value
        try await waitForQuietLog(server)

        XCTAssertEqual(model.currentUserID, accountB, "A's rejected bearer must not clear B's session")
        XCTAssertEqual(model.bootState, .signedIn, "B must stay signed in")
        XCTAssertNil(
            model.lastPartialRefreshFailure,
            "a stale A failure must not publish its summary into B's screens"
        )
        XCTAssertEqual(model.errorMessage, bannerBeforeRelease, "a stale A failure must not surface a banner on B")
        XCTAssertNil(model.dashboardLoadFailureClass, "B's Dashboard must not inherit A's failure state")
    }

    // MARK: - AC1: A -> signed-out -> A, late success (the EPOCH fence)

    /// The same user id signs back in, so only the lifecycle EPOCH distinguishes
    /// the suspended pass from the live account: the pre-sign-out pass must not
    /// publish its (network) result over the returning session.
    func testLateSuccessFromThePreviousEpochNeverPublishesIntoTheReturningAccount() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        let held = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let pass = Task { await model.refreshAll() }
        await expectEntry(held, "the session request reached the transport", server: server)

        await model.signOut()
        try await waitUntil("sign-out cleared the visible account") { model.currentUserID == nil }
        XCTAssertEqual(model.bootState, .signedOut)

        try await signIn(as: accountA, in: harness)
        XCTAssertEqual(
            model.sessions.map(\.id),
            [harness.seededSessionID],
            "the returning A pass published A's own rows"
        )

        held.release(status: 200, body: sessionRowJSON(id: harness.lateRowID, note: "stale A row"))
        await pass.value
        try await waitForQuietLog(server)

        XCTAssertEqual(model.currentUserID, accountA)
        XCTAssertEqual(
            model.sessions.map(\.id),
            [harness.seededSessionID],
            "the pre-sign-out pass must not publish its stale result into the returning epoch"
        )
    }

    // MARK: - AC1: A -> signed-out -> A, late failure

    /// The old pass's error must not become the returning account's error.
    func testLateFailureFromThePreviousEpochNeverSurfacesInTheReturningAccount() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        let held = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let pass = Task { await model.refreshAll() }
        await expectEntry(held, "the session request reached the transport", server: server)

        await model.signOut()
        try await waitUntil("sign-out cleared the visible account") { model.currentUserID == nil }
        try await signIn(as: accountA, in: harness)
        let failureBeforeRelease = model.lastPartialRefreshFailure
        let dashboardBeforeRelease = model.dashboardLoadFailureClass
        let bannerBeforeRelease = model.errorMessage
        XCTAssertNil(failureBeforeRelease)
        XCTAssertNil(dashboardBeforeRelease)

        held.release(status: 503, body: Data(#"{"message":"upstream unavailable"}"#.utf8))
        await pass.value
        try await waitForQuietLog(server)

        XCTAssertEqual(
            model.lastPartialRefreshFailure,
            failureBeforeRelease,
            "a stale pass's failure must not publish into the new epoch"
        )
        XCTAssertEqual(model.dashboardLoadFailureClass, dashboardBeforeRelease)
        XCTAssertEqual(model.errorMessage, bannerBeforeRelease)
        XCTAssertEqual(model.currentUserID, accountA)
    }

    // MARK: - AC3: cache hydration

    /// Cache hydration is the launch/account-switch read that renders the local
    /// snapshot before any network request starts. A hydration read suspended
    /// across the switch must not publish A's cached rows into B.
    func testAStaleCacheHydrationNeverPublishesTheOldAccountsRowsIntoTheNewAccount() async throws {
        let gate = HoldGate()
        let harness = try await makeHarness(beforeSnapshotRead: { await gate.wait() })
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }
        defer { Task { await gate.open() } }

        XCTAssertEqual(model.sessions.map(\.id), [harness.seededSessionID])

        // Hold this pass's hydration read inside storage.
        await gate.arm()
        let pass = Task { await model.refreshAll() }
        let entered = await gate.waitForEntry()
        XCTAssertTrue(entered, "A's hydration read must reach the storage gate")

        try await signIn(as: accountB, in: harness)
        XCTAssertFalse(
            model.sessions.contains { $0.id == harness.seededSessionID },
            "B's own hydration/publish must show B's empty snapshot"
        )

        await gate.open()
        await pass.value
        try await waitForQuietLog(server)

        XCTAssertEqual(
            model.sessions,
            [],
            "A's suspended hydration must not publish A's cache rows into B"
        )
        XCTAssertEqual(model.currentUserID, accountB)
    }

    // MARK: - AC3: overlapping newer request (the same-account token fence)

    /// Two overlapping passes for the SAME account/epoch. `isRefreshing` is
    /// owned by a token, not just by the account: the older pass's completion
    /// must not clear the newer pass's spinner while the newer one is running.
    func testAnOverlappingNewerRequestKeepsTheSpinnerItOwns() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        let firstHold = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let first = Task { await model.refreshAll() }
        await expectEntry(firstHold, "the first pass reached the transport", server: server)
        XCTAssertTrue(model.isRefreshing)

        let secondHold = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let second = Task { await model.refreshAll() }
        await expectEntry(secondHold, "the second pass reached the transport", server: server)
        XCTAssertTrue(model.isLoadingData, "both passes hold a data-refresh lease")

        firstHold.release()
        await first.value
        try await waitForQuietLog(server, quietFor: 0.2)

        XCTAssertTrue(
            model.isRefreshing,
            "the older pass must not clear the newer pass's spinner (AccountScopedCompletion.owns)"
        )
        XCTAssertTrue(model.isLoadingData, "the newer pass still owns its data-refresh lease")

        secondHold.release()
        await second.value
        try await waitUntil("the owning pass released the spinner") { model.isRefreshing == false }
        XCTAssertFalse(model.isLoadingData)
    }

    // MARK: - AC3: cancellation

    /// A cancelled in-flight pass publishes nothing: no rows, no failure, and
    /// it still releases the spinner it owns.
    func testACancelledInFlightPassPublishesNothing() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        let held = server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
        let failureBeforePass = model.lastPartialRefreshFailure
        let dashboardBeforePass = model.dashboardLoadFailureClass
        let bannerBeforePass = model.errorMessage
        let pass = Task { await model.refreshAll() }
        await expectEntry(held, "the session request reached the transport", server: server)

        pass.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        held.release(status: 200, body: sessionRowJSON(id: harness.lateRowID, note: "cancelled pass row"))
        _ = await pass.value
        try await waitForQuietLog(server)

        XCTAssertEqual(
            model.sessions.map(\.id),
            [harness.seededSessionID],
            "a cancelled pass must not publish the result it was carrying"
        )
        XCTAssertEqual(model.lastPartialRefreshFailure, failureBeforePass, "a cancelled pass is not a failure")
        XCTAssertEqual(model.errorMessage, bannerBeforePass)
        XCTAssertEqual(model.dashboardLoadFailureClass, dashboardBeforePass)
        XCTAssertFalse(model.isRefreshing, "the pass released its own spinner")
        XCTAssertEqual(model.currentUserID, accountA)
    }

    // MARK: - AC2: an A-owned mutation completing after the switch

    /// A real durable mutation (`savePreset` -> `DirectWriteIntent` ->
    /// `startQueueUpload` -> `AppModel.upload` -> `repository.insertPreset`) is
    /// suspended inside the transport, the account switches to B, B has its own
    /// pending write, and only then does A's request answer.
    ///
    /// Proved: A's acknowledged row never enters B's published list; B's
    /// pending state is neither cleared nor republished by A's completion; and
    /// an A-owned retry never leaves the device carrying B's credentials. The
    /// replacement retry is armed deliberately — A's queue identity is
    /// re-authored while the first request is in flight, so `upload`'s defer
    /// has a replacement to re-attempt at the boundary.
    func testAnAOwnedMutationCompletionNeverEntersTheNewAccountsContext() async throws {
        let harness = try await makeHarness()
        let model = harness.model
        let server = harness.server
        defer { cleanUp(harness) }

        let presetA = Self.makePreset(name: "A in-flight \(UUID().uuidString)")
        var rewritten = presetA
        rewritten.name = "\(presetA.name) revised"

        let firstInsert = server.holdNext(method: "POST", pathSuffix: "/tindeq_presets")
        let accepted = await model.savePreset(presetA, isNew: true)
        XCTAssertTrue(accepted, "A's durable intent must be persisted")
        await expectEntry(firstInsert, "A's insert must reach the transport", server: server)
        XCTAssertEqual(
            server.loggedRequests.last {
                $0.method == "POST" && $0.path.hasSuffix("/tindeq_presets")
            }?.bearer,
            "Bearer \(Self.accessToken(for: accountA))",
            "the suspended request is A's, carrying A's credential"
        )

        // A newer A-authored word for the same queue identity while the request
        // is in flight: the durable item is replaced, so the completing upload
        // finds a replacement to re-attempt.
        let rewrittenAccepted = await model.savePreset(rewritten, isNew: false)
        XCTAssertTrue(rewrittenAccepted)

        try await signIn(as: accountB, in: harness)

        // B's own pending write, held at the transport, so B's queue state is
        // visible and non-zero while A's completion lands.
        let presetB = Self.makePreset(name: "B in-flight \(UUID().uuidString)")
        let secondInsert = server.holdNext(method: "POST", pathSuffix: "/tindeq_presets")
        let bAccepted = await model.savePreset(presetB, isNew: true)
        XCTAssertTrue(bAccepted, "B's durable intent must be persisted")
        await expectEntry(secondInsert, "B's insert must reach the transport", server: server)
        await model.drainQueue()
        XCTAssertEqual(model.queuedWriteCount, 1, "B's own pending write is visible")

        // Now A's suspended request answers.
        firstInsert.release(status: 201, body: presetRowJSON(name: rewritten.name))
        try await waitForQuietLog(server)

        XCTAssertFalse(
            model.presets.contains { $0.name == rewritten.name },
            "A's acknowledged row must never enter B's published preset list"
        )
        XCTAssertEqual(model.queuedWriteCount, 1, "A's completion must not republish or clear B's pending state")
        XCTAssertEqual(queueCount(for: accountB), 1, "B's durable intent is untouched on disk")
        XCTAssertEqual(model.currentUserID, accountB)
        XCTAssertEqual(model.bootState, .signedIn)

        // No A-owned work may be re-sent under B's credentials.
        let crossed = server.loggedRequests.filter { request in
            request.method != "GET"
                && request.bearer == "Bearer \(Self.accessToken(for: accountB))"
                && request.body.contains(rewritten.name)
        }
        XCTAssertTrue(
            crossed.isEmpty,
            "an A-owned retry must never reach the backend with B's credential: \(crossed.map(\.path))"
        )

        secondInsert.release(status: 201, body: presetRowJSON(name: presetB.name))
        try await waitForQuietLog(server)
        XCTAssertEqual(model.queuedWriteCount, 0, "B's own upload completes normally")
        XCTAssertEqual(queueCount(for: accountA), 1, "A's intent stays owned by A")
    }

    // MARK: - #980: the pre-event credential window

    /// #980: the SDK stores the new account's session BEFORE the model's
    /// auth-event loop handles `.signedIn` (`AppModel.handleAuthEvent` runs
    /// serially on `authStateChanges`, and it is parked inside account A's
    /// `.initialSession` bootstrap while the held request is suspended).
    /// Signing in as B in that window leaves the SDK's credential source
    /// holding B's session while `currentUserID` is still A — so any
    /// A-owned work that reaches the transport in this window would be built
    /// with B's bearer (`AuthService.ensureFreshSession` reads the live SDK
    /// session).
    ///
    /// This test opens that window deliberately, releases an A-owned durable
    /// retry inside it, and asserts the credentials the retry actually goes
    /// out with — plus that the window was real (both holds still outstanding
    /// at the switch, `currentUserID` still A).
    func testAPreEventWindowRetryNeverCarriesTheUnacceptedAccountsBearer() async throws {
        let harness = try await makeHarness(holdBootstrap: true)
        let model = harness.model
        let server = harness.server
        guard let bootstrapHold = harness.bootstrapHold else {
            XCTFail("the window harness must hold the bootstrap request")
            return
        }
        defer { cleanUp(harness) }
        defer { bootstrapHold.release(status: 200, body: Data("[]".utf8)) }

        // The window's premise: A's bootstrap is parked inside the auth-event
        // loop and its own request is genuinely UNANSWERED. An instantly
        // released hold (the #933 invalidated run) would show
        // `isOutstanding == false` right here.
        XCTAssertEqual(model.currentUserID, accountA)
        XCTAssertEqual(
            model.bootState,
            .loading,
            "A's bootstrap is still inside handleAuthEvent(.initialSession)"
        )
        XCTAssertTrue(
            bootstrapHold.isOutstanding,
            "the window is held open by a genuinely suspended bootstrap request"
        )

        var capturedFailures: [PersistedFailureLine] = []
        model.persistedFailureSink = PersistedFailureSink { line in
            capturedFailures.append(line)
        }

        let presetA = Self.makePreset(name: "pre-event window \(UUID().uuidString)")
        var rewritten = presetA
        rewritten.name = "\(presetA.name) revised"

        // A's durable write, in flight before the switch.
        let firstInsert = server.holdNext(method: "POST", pathSuffix: "/tindeq_presets")
        let accepted = await model.savePreset(presetA, isNew: true)
        XCTAssertTrue(accepted, "A's durable intent must be persisted")
        await expectEntry(firstInsert, "A's insert must reach the transport", server: server)
        XCTAssertTrue(
            firstInsert.isOutstanding,
            "A's insert is genuinely suspended, not merely requested"
        )
        XCTAssertEqual(
            bearerAccountName(server.loggedRequests.last {
                $0.method == "POST" && $0.path.hasSuffix("/tindeq_presets")
            }?.bearer),
            "account A's",
            "the pre-switch request is A's and carries A's credential"
        )

        // Re-author the same queue identity while the first request is in
        // flight: the completing upload's defer then has a replacement to
        // re-attempt. That retry is the request this test observes.
        let rewrittenAccepted = await model.savePreset(rewritten, isNew: false)
        XCTAssertTrue(rewrittenAccepted, "A's replacement intent must be persisted")

        // --- THE WINDOW ----------------------------------------------------
        // The SDK stores B's session here. The model's auth-event loop is
        // still parked in A's bootstrap, so the `.signedIn` event queues up
        // behind the held request and `currentUserID` stays A.
        server.signInUserID = accountB
        await model.signIn(email: "\(accountB.uuidString)@example.test", password: "probe-password")

        XCTAssertEqual(
            harness.authClient.currentSession?.user.id,
            accountB,
            "the SDK's credential source already holds B's session"
        )
        XCTAssertEqual(
            model.currentUserID,
            accountA,
            "the model has not processed .signedIn yet — this is the window"
        )
        XCTAssertTrue(bootstrapHold.isOutstanding, "the window is still held open")
        XCTAssertTrue(firstInsert.isOutstanding, "A's insert is still in flight at the switch")

        // Release A's insert; its defer re-attempts the replacement NOW, while
        // the model still publishes A.
        let retryHold = server.holdNext(method: "POST", pathSuffix: "/tindeq_presets")
        firstInsert.release(status: 201, body: presetRowJSON(name: rewritten.name))
        let retryArrived = await retryHold.waitForEntry(timeout: 15)
        // Bound the wait for whichever outcome this build produces: the retry
        // reaching the transport (pre-fix) or its local refusal (post-fix).
        try await waitUntil("the window retry settled", timeout: 15) {
            retryArrived || !capturedFailures.isEmpty
        }
        try await waitForQuietLog(server)

        // Sampled INSIDE the window: every request the transport has seen so
        // far arrived while the model published account A.
        let requestsAtSample = server.loggedRequests.count
        let windowRequests = Array(server.loggedRequests.prefix(requestsAtSample))
        let crossed = windowRequests.filter { request in
            request.bearer == "Bearer \(Self.accessToken(for: accountB))"
                && !request.path.contains("/auth/v1/")
        }
        // The committed log must carry the window's own state, not only its
        // failures: holds still outstanding, who the model publishes, who the
        // SDK would hand out, and where the retry went. Account ids and hold
        // states only — never token text.
        print(
            "[#980] window sample: currentUserID=\(model.currentUserID?.uuidString ?? "nil") "
                + "sdkSessionUser=\(harness.authClient.currentSession?.user.id.uuidString ?? "nil") "
                + "bootstrapOutstanding=\(bootstrapHold.isOutstanding) "
                + "insertOutstanding=\(firstInsert.isOutstanding) "
                + "retryArrived=\(retryArrived) "
                + "crossed=\(crossed.map { "\($0.method) \($0.path)" }) "
                + "refusedLocally=\(capturedFailures.map(\.operation))"
        )
        XCTAssertTrue(
            crossed.isEmpty,
            """
            an A-owned request must never reach the backend with the unaccepted \
            account's credential: crossed=\(crossed.map { "\($0.method) \($0.path)" }), \
            retryArrived=\(retryArrived), \
            currentUserID=\(String(describing: model.currentUserID)), \
            sdkSession=\(String(describing: harness.authClient.currentSession?.user.id)), \
            transport saw \(server.requestSummary)
            """
        )
        XCTAssertEqual(
            model.currentUserID,
            accountA,
            "the sample must be taken inside the window"
        )

        // The retry must have run and been refused before the transport — a
        // green run in which it was never attempted would prove nothing.
        let refusals = capturedFailures.filter { $0.operation == "queue-upload:preset" }
        XCTAssertFalse(
            refusals.isEmpty,
            """
            the window retry must be attempted and refused locally \
            (retryArrived=\(retryArrived)); \
            attempted=\(capturedFailures.map(\.operation))
            """
        )

        // --- Unwind: let the queued `.signedIn` through and settle B. -------
        retryHold.release(status: 201, body: presetRowJSON(name: rewritten.name))
        bootstrapHold.release(status: 200, body: Data("[]".utf8))
        try await waitUntil("account B became currentUserID", timeout: 120) {
            model.currentUserID == self.accountB
        }
        try await waitUntil("account B's bootstrap finished", timeout: 120) {
            model.bootState == .signedIn
                && model.isRefreshing == false
                && model.isLoadingData == false
        }
        XCTAssertEqual(
            queueCount(for: accountA),
            1,
            "A's intent stays owned by A — an unaccepted account's credential must not acknowledge it"
        )
    }

    // MARK: - Harness

    private struct Harness {
        let model: AppModel
        let server: AccountSwitchPostgREST
        let directory: URL
        let seededSessionID: UUID
        let lateRowID: UUID
        /// #980: the SDK's own credential store, so a test can assert what the
        /// SDK would hand a request built at this moment.
        let authClient: AuthClient
        /// #980: non-nil only for the window harness — the bootstrap request
        /// whose suspension parks the auth-event loop inside account A's
        /// `.initialSession` handling.
        let bootstrapHold: AccountSwitchPostgREST.Hold?
    }

    /// Sends a real `.signedIn` through the SDK's `authStateChanges` by signing
    /// in against the stubbed token endpoint, then waits for that account's
    /// bootstrap to finish publishing.
    ///
    /// The bootstrap ends with a best-effort realtime join whose WebSocket
    /// handshake cannot complete against the stub, so the auth-event loop is
    /// busy for those bounded retries; the waits are generous on purpose.
    private func signIn(as userID: UUID, in harness: Harness) async throws {
        harness.server.signInUserID = userID
        await harness.model.signIn(email: "\(userID.uuidString)@example.test", password: "probe-password")
        try await waitUntil("account \(userID) became currentUserID", timeout: 90) {
            harness.model.currentUserID == userID
        }
        try await waitUntil("account \(userID) bootstrap finished", timeout: 120) {
            harness.model.bootState == .signedIn &&
                harness.model.isRefreshing == false &&
                harness.model.isLoadingData == false
        }
    }

    /// Waits (without blocking the main actor) until a held request arrives,
    /// then reports the transport's own view of what it received when it did
    /// not.
    private func expectEntry(
        _ hold: AccountSwitchPostgREST.Hold,
        _ description: String,
        server: AccountSwitchPostgREST
    ) async {
        let arrived = await hold.waitForEntry(timeout: 20)
        XCTAssertTrue(arrived, "\(description) — transport saw \(server.requestSummary)")
    }

    /// Names which fixture account a logged request's bearer belongs to,
    /// WITHOUT printing the credential: the lane's logs are committed, so no
    /// token text (even the deterministic fixture JWT) goes into a message.
    private func bearerAccountName(_ bearer: String?) -> String {
        guard let bearer else { return "no" }
        if bearer == "Bearer \(Self.accessToken(for: accountA))" { return "account A's" }
        if bearer == "Bearer \(Self.accessToken(for: accountB))" { return "account B's" }
        return "an unexpected"
    }

    private func makeHarness(
        beforeSnapshotRead: @escaping @Sendable () async -> Void = {},
        holdBootstrap: Bool = false
    ) async throws -> Harness {
        let seededSessionID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-switch-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("cache.sqlite")
        try seedCache(
            at: databaseURL,
            userID: accountA,
            sessionID: seededSessionID,
            note: "A's cached row"
        )

        let server = AccountSwitchPostgREST()
        server.signInUserID = accountA
        // #980: when the test needs the pre-event window, the bootstrap's own
        // sessions request is registered as a hold BEFORE the model exists, so
        // no request can slip past it. `handleAuthEvent(.initialSession)` is
        // serial on the auth-event loop and awaits this request, so the loop
        // parks here — with `authSession` already set to account A — until the
        // test releases it.
        let bootstrapHold: AccountSwitchPostgREST.Hold? = holdBootstrap
            ? server.holdNext(method: "GET", pathSuffix: "/rest/v1/sessions")
            : nil
        let suite = "AccountSwitchInFlightAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = SwitchAuthStorage()
        try storage.store(
            key: Self.authStorageKey,
            value: JSONEncoder().encode(Self.makeSession(userID: accountA))
        )
        let client = SupabaseClient(
            supabaseURL: Self.projectURL,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: storage,
                    autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                ),
                global: SupabaseClientOptions.GlobalOptions(session: server.makeURLSession())
            )
        )
        let auth = AuthService(
            client: client,
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
        // #679's production wiring: the transport's bearer token comes from the
        // live SDK session, so an A-owned request that escaped the fence after a
        // switch would carry B's token.
        let repository = SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: Self.projectURL,
                apiKey: "test-key",
                authClient: client.auth,
                sessionProvider: { try await auth.ensureFreshSession() },
                serverClock: auth.serverClock,
                session: server.makeURLSession()
            )
        )
        let model = AppModel(
            auth: auth,
            repository: repository,
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession()),
            cacheStorageSeams: CacheStorageSeams(
                openStore: { _ in try LocalCacheStore(databaseURL: databaseURL) },
                beforeSnapshotRead: beforeSnapshotRead
            )
        )
        // SplashView calls this on first presentation; the test-hosted model has
        // no view hierarchy, so the bootstrap's splash floor would otherwise
        // hold `bootState` at `.loading` for ever.
        model.splashPresented(at: Date())
        try await waitUntil("the seeded account A session became currentUserID", timeout: 90) {
            model.currentUserID == self.accountA
        }
        if let bootstrapHold {
            // #980: the window harness stops HERE. Account A is the published
            // account and the auth-event loop is parked inside A's bootstrap;
            // the bootstrap request must be genuinely suspended, not merely
            // requested.
            let entered = await bootstrapHold.waitForEntry(timeout: 120)
            XCTAssertTrue(
                entered,
                "the bootstrap sessions request must be held open — transport saw \(server.requestSummary)"
            )
        } else {
            try await waitUntil("account A's bootstrap finished", timeout: 120) {
                model.bootState == .signedIn && model.hasLoadedSessions && model.isRefreshing == false
            }
        }
        return Harness(
            model: model,
            server: server,
            directory: directory,
            seededSessionID: seededSessionID,
            lateRowID: UUID(),
            authClient: client.auth,
            bootstrapHold: bootstrapHold
        )
    }

    private func cleanUp(_ harness: Harness) {
        // The durable queue file is shared app-container state that other
        // suites read, and `PendingWrite` is app-model-private (this target
        // cannot open a `DurableQueue` handle over it). A test's own items are
        // left on disk instead of rewriting that file by hand — they are keyed
        // to this test's fresh account UUIDs, so no other account's count can
        // observe them.
        try? FileManager.default.removeItem(at: harness.directory)
    }

    // MARK: - Queue file

    private static var queueFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
            .appendingPathComponent("pending-writes.json", isDirectory: false)
    }

    /// The durable queue's on-disk truth, read straight from the file the app
    /// writes (`DurableQueue` keeps its own in-memory copy, so a second handle
    /// would answer from a stale snapshot).
    private func queueCount(for userID: UUID) -> Int {
        struct StoredItem: Decodable { let accountUserID: UUID }
        struct Store: Decodable { let items: [StoredItem] }
        guard let data = try? Data(contentsOf: Self.queueFileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return 0
        }
        return store.items.filter { $0.accountUserID == userID }.count
    }

    /// Seeds account A's cache the way a previous run leaves it: one session row
    /// plus its cursor, so the refresh takes the delta path and the publication
    /// reads this snapshot back.
    private func seedCache(
        at databaseURL: URL,
        userID: UUID,
        sessionID: UUID,
        note: String
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = try LocalCacheStore(databaseURL: databaseURL)
        let workspace = CachedWorkspace(store: store)
        let session = SendmeterCore.Session(
            id: sessionID,
            date: "2026-09-01",
            type: "fingerboard",
            typeLabel: "Fingerboard",
            durationMinutes: 45,
            rpe: 8,
            note: note,
            phase: .capacity
        )
        try workspace.upsertLocal(
            session,
            accountUserID: userID,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        try workspace.setCursor(
            "2026-08-01T00:00:00.000000Z",
            accountUserID: userID,
            entityType: .sessions
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 20,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out after \(timeout)s waiting for: \(description)")
    }

    /// Waits until the transport has been idle for `quietFor` seconds, so an
    /// assertion about "no request was issued" is made after every in-flight
    /// producer had a chance to issue one.
    private func waitForQuietLog(
        _ server: AccountSwitchPostgREST,
        quietFor: TimeInterval = 0.4,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var count = server.requestCount
        var quietSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let latest = server.requestCount
            if latest != count {
                count = latest
                quietSince = Date()
            }
            if Date().timeIntervalSince(quietSince) >= quietFor { return }
        }
    }

    // MARK: - Fixtures

    private static let projectURL = URL(string: "https://example.test")!
    private static let authStorageKey = "sb-example-auth-token"

    private static func makeSession(userID: UUID) -> Auth.Session {
        let user = Auth.User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return Auth.Session(
            accessToken: accessToken(for: userID),
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-\(userID.uuidString)",
            user: user
        )
    }

    /// The deterministic bearer the SDK stores for an account, so a test can
    /// name the credential a request carried.
    private static func accessToken(for userID: UUID) -> String {
        jwt(for: userID)
    }

    private static func makePreset(name: String) -> TindeqPreset {
        TindeqPreset(
            name: name,
            holdSeconds: 7,
            repetitions: 5,
            sets: 3,
            restBetweenRepetitionsSeconds: 3,
            restBetweenSetsSeconds: 120
        )
    }
}

// MARK: - Shared fixture builders

/// A deterministic, structurally valid JWT for an account: the SDK stores the
/// string verbatim and the app's descriptor only reads its claims.
private func jwt(for userID: UUID) -> String {
    let claims = #"{"session_id":"session-\#(userID.uuidString)","iat":1000,"exp":4102444800}"#
    let payload = Data(claims.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    return "header.\(payload).signature"
}

/// One `climb_sessions`/`sessions` delta row, ordered after the seeded cursor.
private func sessionRowJSON(id: UUID, note: String) -> Data {
    let row: [String: Any] = [
        "id": id.uuidString.lowercased(),
        "date": "2026-09-15",
        "type": "fingerboard",
        "type_label": "Fingerboard",
        "duration_min": 30,
        "rpe": 7,
        "rpe_confirmed": true,
        "load": 210,
        "note": note,
        "phase": "capacity",
        "group_id": NSNull(),
        "workout_source": NSNull(),
        "updated_at": "2026-09-15T00:00:00.000000Z",
        "deleted_at": NSNull(),
    ]
    return (try? JSONSerialization.data(withJSONObject: [row])) ?? Data("[]".utf8)
}

/// The row a successful `tindeq_presets` insert answers with. The column names
/// are the wire form `PresetRow.CodingKeys` decodes (`hold_s`/`reps`/…), and the
/// four non-optional numerics plus `updated_at` must all be present.
private func presetRowJSON(name: String) -> Data {
    let row: [String: Any] = [
        "id": UUID().uuidString.lowercased(),
        "name": name,
        "hold_s": 7,
        "reps": 5,
        "sets": 3,
        "rest_reps_s": 3,
        "rest_sets_s": 120,
        "deleted_at": NSNull(),
        "updated_at": "2026-09-20T00:00:00.000000Z",
    ]
    return (try? JSONSerialization.data(withJSONObject: [row])) ?? Data("[]".utf8)
}

// MARK: - Transport double

/// A hermetic PostgREST/Auth server. Requests are recorded in arrival order
/// (before any hold blocks), specific requests can be held open and answered
/// later, and the auth endpoints mint real SDK sessions so `authStateChanges`
/// drives the production account boundary.
private final class AccountSwitchPostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    struct LoggedRequest {
        let method: String
        let path: String
        let query: String
        let body: String
        let bearer: String?
    }

    /// A single-shot hold: the matching request is SUSPENDED (its URLProtocol
    /// returns without answering) until the test releases it with the answer
    /// that arrives "late".
    ///
    /// It must not block the protocol thread: CFNetwork services every custom
    /// URLProtocol in the process on ONE `com.apple.CFNetwork.CustomProtocols`
    /// runloop thread (proved with `sample`: a blocked `startLoading` stalls
    /// every other stubbed request), so a blocked hold would freeze the very
    /// second pass or second account a test is trying to overlap with.
    final class Hold {
        let method: String
        let pathSuffix: String
        private let stateLock = NSLock()
        private var reply: Reply?
        private var released = false
        private var entered = false
        private var delivered = false
        private weak var suspendedProtocol: AccountSwitchProtocol?
        private var suspendedRequest: URLRequest?

        init(method: String, pathSuffix: String) {
            self.method = method
            self.pathSuffix = pathSuffix
        }

        func matches(method: String, path: String) -> Bool {
            self.method == method && path.hasSuffix(pathSuffix)
        }

        var hasEntered: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return entered
        }

        /// #980: whether the matching request has reached the transport and is
        /// still UN-ANSWERED — i.e. the hold really holds. A hold that released
        /// instantly (the #933 invalidated-run bug) reads `false` here even
        /// when `hasEntered` is true, so a window built on it would be a
        /// fabricated one.
        var isOutstanding: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return entered && !delivered
        }

        fileprivate func suspend(_ urlProtocol: AccountSwitchProtocol, request: URLRequest) {
            stateLock.lock()
            entered = true
            suspendedProtocol = urlProtocol
            suspendedRequest = request
            let pending = released && !delivered ? reply : nil
            if pending != nil { delivered = true }
            stateLock.unlock()
            if let pending {
                Self.deliver(pending, to: urlProtocol, request: request)
            }
        }

        func waitForEntry(timeout: TimeInterval = 20) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if hasEntered { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return hasEntered
        }

        func release(status: Int = 200, body: Data = Data("[]".utf8)) {
            stateLock.lock()
            reply = Reply(status: status, body: body)
            released = true
            let ready = suspendedProtocol != nil && !delivered
            let urlProtocol = suspendedProtocol
            let request = suspendedRequest
            if ready { delivered = true }
            stateLock.unlock()
            if ready, let urlProtocol, let request {
                Self.deliver(Reply(status: status, body: body), to: urlProtocol, request: request)
            }
        }

        private static func deliver(
            _ reply: Reply,
            to urlProtocol: AccountSwitchProtocol,
            request: URLRequest
        ) {
            AccountSwitchProtocol.deliver(reply, to: urlProtocol, request: request)
        }
    }

    var signInUserID: UUID?

    private let lock = NSLock()
    private var holds: [Hold] = []
    private var requests: [LoggedRequest] = []

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountSwitchProtocol.self]
        AccountSwitchProtocol.server = self
        return URLSession(configuration: configuration)
    }

    @discardableResult
    func holdNext(method: String, pathSuffix: String) -> Hold {
        let hold = Hold(method: method, pathSuffix: pathSuffix)
        lock.lock()
        holds.append(hold)
        lock.unlock()
        return hold
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var loggedRequests: [LoggedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// A compact diagnostic of everything the transport received, so a failed
    /// hold or an unexpected request can be read off the log.
    var requestSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { "\($0.method) \($0.path)" }.joined(separator: ", ")
    }

    /// The transport's answer for one request: an immediate reply, or a hold
    /// that keeps the task in flight until the test releases it.
    enum Outcome {
        case answer(Reply)
        case suspend(Hold)
    }

    func reply(for request: URLRequest, body: Data?) -> Outcome {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        let recordedBody = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        lock.lock()
        requests.append(
            LoggedRequest(
                method: method,
                path: path,
                query: query,
                body: recordedBody,
                bearer: bearer
            )
        )
        let hold = holds.firstIndex { $0.matches(method: method, path: path) }
            .map { holds.remove(at: $0) }
        lock.unlock()

        if let hold {
            return .suspend(hold)
        }
        return .answer(immediateReply(method: method, path: path, query: query, body: body))
    }

    private func immediateReply(method: String, path: String, query: String, body: Data?) -> Reply {
        if path.contains("/auth/v1/token") {
            return Reply(status: 200, body: authSessionJSON(for: signInUserID))
        }
        if path.contains("/auth/v1/logout") {
            return Reply(status: 204, body: Data())
        }
        if path.contains("/auth/v1/") {
            // Passkeys and the other GoTrue reads answer an empty collection.
            return Reply(status: 200, body: Data("[]".utf8))
        }
        if path.hasSuffix("/tindeq_presets"), method == "POST" {
            let name = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["name"] as? String
            return Reply(status: 201, body: presetRowJSON(name: name ?? "unknown"))
        }
        return Reply(status: 200, body: Data("[]".utf8))
    }

    private func authSessionJSON(for userID: UUID?) -> Data {
        let account = userID ?? UUID()
        let id = account.uuidString.lowercased()
        let json = """
        {"access_token":"\(jwt(for: account))",\
        "token_type":"bearer","expires_in":3600,"expires_at":4102444800,\
        "refresh_token":"refresh-\(id)",\
        "user":{"id":"\(id)","aud":"authenticated",\
        "created_at":"2026-09-01T00:00:00.000000Z","updated_at":"2026-09-01T00:00:00.000000Z",\
        "app_metadata":{},"user_metadata":{}}}
        """
        return Data(json.utf8)
    }
}

private final class AccountSwitchProtocol: URLProtocol {
    nonisolated(unsafe) static var server: AccountSwitchPostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body to URLProtocol as a stream, never as
        // `httpBody`; the JSON payload must be drained here.
        let body = Self.drain(request.httpBodyStream)
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch server.reply(for: request, body: body) {
        case .answer(let reply):
            Self.deliver(reply, to: self, request: request)
        case .suspend(let hold):
            // The task stays in flight; the test answers it later. Returning
            // here (instead of blocking) keeps CFNetwork's single custom-
            // protocol runloop thread free for every other request.
            hold.suspend(self, request: request)
        }
    }

    override func stopLoading() {}

    static func deliver(_ reply: AccountSwitchPostgREST.Reply, to urlProtocol: URLProtocol, request: URLRequest) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: URLError(.badServerResponse))
            return
        }
        urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: reply.body)
        }
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - Auth storage double

private final class SwitchAuthStorage: AuthLocalStorage {
    private var store: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        store[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        store[key]
    }

    func remove(key: String) throws {
        store.removeValue(forKey: key)
    }
}

// MARK: - Storage-side hold

/// Holds the storage side of the next snapshot read (the cache hydration) until
/// the test releases it, so the pass suspends inside storage rather than on the
/// network.
private actor HoldGate {
    private var isArmed = false
    private var entries = 0
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
    }

    func wait() async {
        guard isArmed else { return }
        isArmed = false
        entries += 1
        let waiters = entryWaiters
        entryWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitForEntry(timeout: TimeInterval = 20) async -> Bool {
        if entries > 0 { return true }
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.abandonEntryWait()
        }
        defer { deadline.cancel() }
        await withCheckedContinuation { entryWaiters.append($0) }
        return entries > 0
    }

    func open() {
        let waiters = openWaiters
        openWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func abandonEntryWait() {
        guard entries == 0 else { return }
        let waiters = entryWaiters
        entryWaiters = []
        waiters.forEach { $0.resume() }
    }
}
