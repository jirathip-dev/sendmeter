import XCTest
@testable import SendmeterCore

/// #942: the pure planning half of the History Merge action. The RPC
/// (`merge_tindeq_sessions`) enforces the same guardrails server-side; these
/// tests pin the app-side plan: which session survives, which recordings move,
/// and what duration/note/RPE the merged entry ends up with.
final class TindeqSessionMergeTests: XCTestCase {
    // 2026-01-20 00:00:00Z, so the fixture times below are that local day.
    private let day = "2026-01-20"
    private let tenAM: TimeInterval = 1_768_903_200
    private let halfPastTen: TimeInterval = 1_768_905_000
    private let elevenAM: TimeInterval = 1_768_906_800

    private let groupA = UUID(uuidString: "94200000-0000-0000-0000-0000000000a1")!
    private let groupB = UUID(uuidString: "94200000-0000-0000-0000-0000000000a2")!
    private let groupC = UUID(uuidString: "94200000-0000-0000-0000-0000000000a3")!
    private let stride = UUID(uuidString: "94200000-0000-0000-0000-0000000000a4")!

    private func session(
        id: String,
        date: String? = nil,
        type: String = "tindeq",
        durationMinutes: Int = 30,
        rpe: Double = 6,
        rpeConfirmed: Bool = false,
        groupID: UUID? = nil,
        pending: Bool = false
    ) -> Session {
        Session(
            id: UUID(uuidString: id)!,
            date: date ?? day,
            type: type,
            typeLabel: type == "tindeq" ? "Tindeq" : "Board Climbing",
            durationMinutes: durationMinutes,
            rpe: rpe,
            rpeConfirmed: rpeConfirmed,
            note: "",
            phase: .capacity,
            groupID: groupID,
            pending: pending
        )
    }

    private func recording(
        id: String,
        at: TimeInterval,
        tag: String = "FDP",
        groupID: UUID?
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: at),
            durationMilliseconds: 60_000,
            peakKilograms: 32,
            averageKilograms: 28,
            sampleCount: 2,
            note: "",
            tag: tag,
            side: .left,
            groupID: groupID
        )
    }

    /// The three-session, three-recording fixture the acceptance case uses.
    private func threeSameDaySessions() -> [Session] {
        [
            session(
                id: "94200000-0000-0000-0000-000000000013",
                rpe: 7,
                groupID: groupC
            ),
            session(
                id: "94200000-0000-0000-0000-000000000011",
                rpe: 6,
                groupID: groupA
            ),
            session(
                id: "94200000-0000-0000-0000-000000000012",
                rpe: 5.5,
                groupID: groupB
            ),
        ]
    }

    private func threeRecordings() -> [TindeqRecording] {
        [
            recording(id: "94200000-0000-0000-0000-0000000000c3", at: halfPastTen, groupID: groupB),
            recording(id: "94200000-0000-0000-0000-0000000000c4", at: elevenAM, tag: "MWF", groupID: groupC),
            recording(id: "94200000-0000-0000-0000-0000000000c1", at: tenAM, groupID: groupA),
        ]
    }

    // MARK: Eligibility

    func testEligibilityRequiresTwoDistinctUploadedGroupedSameDayTindeqSessions() {
        let first = session(id: "94200000-0000-0000-0000-000000000011", groupID: groupA)
        let second = session(id: "94200000-0000-0000-0000-000000000012", groupID: groupB)

        XCTAssertEqual(TindeqSessionMergePlanner.eligibility([]), .tooFew)
        XCTAssertEqual(TindeqSessionMergePlanner.eligibility([first]), .tooFew)
        XCTAssertEqual(
            TindeqSessionMergePlanner.eligibility([first, first]),
            .tooFew,
            "the same session twice is still one session"
        )
        XCTAssertEqual(TindeqSessionMergePlanner.eligibility([first, second]), .eligible)

        XCTAssertEqual(
            TindeqSessionMergePlanner.eligibility([
                first,
                session(id: "94200000-0000-0000-0000-000000000016", type: "board", groupID: groupC),
            ]),
            .notTindeq
        )
        XCTAssertEqual(
            TindeqSessionMergePlanner.eligibility([
                first,
                session(id: "94200000-0000-0000-0000-000000000014", date: "2026-01-21", groupID: groupC),
            ]),
            .differentDays
        )
        XCTAssertEqual(
            TindeqSessionMergePlanner.eligibility([
                first,
                session(id: "94200000-0000-0000-0000-000000000016", groupID: groupC, pending: true),
            ]),
            .pendingWrite
        )
        XCTAssertEqual(
            TindeqSessionMergePlanner.eligibility([
                first,
                session(id: "94200000-0000-0000-0000-000000000016", groupID: nil),
            ]),
            .ungrouped
        )
    }

    func testEligibilityRefusalMessagesExistForEveryRefusal() {
        let refusals: [TindeqSessionMergeEligibility] = [
            .tooFew, .notTindeq, .differentDays, .pendingWrite, .ungrouped,
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.isEligible)
            XCTAssertNotNil(refusal.refusalMessage, "\(refusal) needs user-facing copy")
        }
        XCTAssertNil(TindeqSessionMergeEligibility.eligible.refusalMessage)
    }

    // MARK: Candidates

    func testCandidatesOfferOnlySameDayUploadedGroupedTindeqSiblings() {
        let anchor = session(id: "94200000-0000-0000-0000-000000000011", groupID: groupA)
        let candidates = TindeqSessionMergePlanner.candidates(
            for: anchor,
            in: [
                anchor,
                session(id: "94200000-0000-0000-0000-000000000012", groupID: groupB),
                session(id: "94200000-0000-0000-0000-000000000013", groupID: groupC),
                session(id: "94200000-0000-0000-0000-000000000014", date: "2026-01-19", groupID: stride),
                session(id: "94200000-0000-0000-0000-000000000015", type: "board", groupID: stride),
                session(id: "94200000-0000-0000-0000-000000000016", groupID: nil),
                session(id: "94200000-0000-0000-0000-000000000017", groupID: stride, pending: true),
            ]
        )
        XCTAssertEqual(
            candidates.map(\.id.uuidString),
            [
                "94200000-0000-0000-0000-000000000012",
                "94200000-0000-0000-0000-000000000013",
            ]
        )
    }

    // MARK: Plan

    func testPlanMergesEveryRecordingIntoTheEarliestStartedSession() throws {
        let plan = try XCTUnwrap(
            TindeqSessionMergePlanner.plan(
                sessions: threeSameDaySessions(),
                recordings: threeRecordings(),
                curves: []
            )
        )

        XCTAssertEqual(plan.survivorID, UUID(uuidString: "94200000-0000-0000-0000-000000000011")!)
        XCTAssertEqual(
            plan.mergedSessionIDs,
            [
                "94200000-0000-0000-0000-000000000011",
                "94200000-0000-0000-0000-000000000012",
                "94200000-0000-0000-0000-000000000013",
            ].map { UUID(uuidString: $0)! },
            "the merge order is earliest-first"
        )
        XCTAssertEqual(plan.groupID, groupA, "the survivor's group is the recordings' new home")
        XCTAssertEqual(
            plan.recordingIDs,
            [
                "94200000-0000-0000-0000-0000000000c1",
                "94200000-0000-0000-0000-0000000000c3",
                "94200000-0000-0000-0000-0000000000c4",
            ].map { UUID(uuidString: $0)! },
            "every recording of every selected group, chronologically"
        )
        XCTAssertEqual(plan.recordingCount, 3)
        XCTAssertEqual(plan.durationMinutes, 61, "10:00:00 → 11:01:00")
        XCTAssertEqual(plan.note, "3 recordings · FDP, MWF")
        XCTAssertEqual(plan.date, day)
        XCTAssertEqual(plan.type, "tindeq")
    }

    func testPlanIgnoresRecordingsOutsideTheSelectedGroups() throws {
        let foreign = recording(
            id: "94200000-0000-0000-0000-0000000000d9",
            at: tenAM - 3_600,
            tag: "COC",
            groupID: stride
        )
        let plan = try XCTUnwrap(
            TindeqSessionMergePlanner.plan(
                sessions: threeSameDaySessions(),
                recordings: threeRecordings() + [foreign],
                curves: []
            )
        )
        XCTAssertEqual(plan.recordingCount, 3)
        XCTAssertFalse(plan.recordingIDs.contains(foreign.id))
        XCTAssertEqual(plan.note, "3 recordings · FDP, MWF")
    }

    func testPlanPredictsRPEWhenNoSelectedSessionWasConfirmed() throws {
        let sessions = threeSameDaySessions()
        let recordings = threeRecordings()
        let curves = [
            TagForceCurve(tag: "FDP", modality: "static", cf: 20, wPrime: 400),
            TagForceCurve(tag: "MWF", modality: "static", cf: 18, wPrime: 300),
        ]

        let plan = try XCTUnwrap(
            TindeqSessionMergePlanner.plan(
                sessions: sessions,
                recordings: recordings,
                curves: curves
            )
        )

        // The independent prediction over the same chronological set is the
        // value the plan must carry — and it is NOT confirmed by anyone.
        let expected = GaugeSessionRPE.predict(
            recordings: recordings.sorted { $0.recordedAt < $1.recordedAt },
            curves: curves
        )
        XCTAssertFalse(plan.rpeConfirmed)
        XCTAssertEqual(plan.rpe, expected.rpe)

        let merged = try XCTUnwrap(
            plan.merged(survivor: sessions[1])
        )
        XCTAssertFalse(merged.rpeConfirmed)
        XCTAssertEqual(merged.rpe, expected.rpe)
    }

    func testPlanKeepsTheLatestConfirmedRPEAndStaysConfirmed() throws {
        let sessions = threeSameDaySessions()
        // The 10:00 survivor was confirmed at RPE 6; the 11:00 session was
        // confirmed later at 8.5 — the later confirmation wins.
        let withConfirmed = [
            session(
                id: "94200000-0000-0000-0000-000000000011",
                rpe: 6, rpeConfirmed: true, groupID: groupA
            ),
            session(
                id: "94200000-0000-0000-0000-000000000012",
                rpe: 5.5, rpeConfirmed: false, groupID: groupB
            ),
            session(
                id: "94200000-0000-0000-0000-000000000013",
                rpe: 8.5, rpeConfirmed: true, groupID: groupC
            ),
        ]
        let plan = try XCTUnwrap(
            TindeqSessionMergePlanner.plan(
                sessions: withConfirmed,
                recordings: threeRecordings(),
                curves: [TagForceCurve(tag: "FDP", modality: "static", cf: 1, wPrime: 1)]
            )
        )
        XCTAssertEqual(plan.rpe, 8.5, "the latest confirmed RPE is kept")
        XCTAssertTrue(plan.rpeConfirmed)
        XCTAssertEqual(plan.survivorID, withConfirmed[0].id, "the earliest session still survives")
        XCTAssertEqual(plan.mergedSessionIDs.count, sessions.count)
    }

    func testPlanFallsBackToTheSurvivorsDurationWhenThereIsNothingToMeasure() throws {
        let empty = [
            session(id: "94200000-0000-0000-0000-000000000012", durationMinutes: 20, groupID: groupB),
            session(id: "94200000-0000-0000-0000-000000000011", durationMinutes: 45, groupID: groupA),
        ]
        let plan = try XCTUnwrap(
            TindeqSessionMergePlanner.plan(sessions: empty, recordings: [], curves: [])
        )
        XCTAssertEqual(
            plan.survivorID,
            UUID(uuidString: "94200000-0000-0000-0000-000000000011")!,
            "no recordings to order by: the deterministic id order decides"
        )
        XCTAssertEqual(plan.durationMinutes, 45, "the survivor's own duration is kept")
        XCTAssertEqual(plan.note, "0 recordings")
        XCTAssertTrue(plan.recordingIDs.isEmpty)
    }

    func testPlanRefusesAnIneligibleSelection() {
        let crossDay = [
            session(id: "94200000-0000-0000-0000-000000000011", groupID: groupA),
            session(id: "94200000-0000-0000-0000-000000000014", date: "2026-01-19", groupID: stride),
        ]
        XCTAssertNil(
            TindeqSessionMergePlanner.plan(sessions: crossDay, recordings: [], curves: [])
        )
    }

    func testMergedRowKeepsTheSurvivorsIdentityAndAppliesThePlan() throws {
        let sessions = threeSameDaySessions()
        let plan = try XCTUnwrap(
            TindeqSessionMergePlanner.plan(
                sessions: sessions,
                recordings: threeRecordings(),
                curves: []
            )
        )
        let survivor = sessions[1]

        let merged = plan.merged(survivor: survivor)

        XCTAssertEqual(merged.id, survivor.id)
        XCTAssertEqual(merged.date, survivor.date)
        XCTAssertEqual(merged.phase, survivor.phase)
        XCTAssertEqual(merged.type, "tindeq")
        XCTAssertEqual(merged.groupID, groupA)
        XCTAssertEqual(merged.durationMinutes, 61)
        XCTAssertEqual(merged.note, "3 recordings · FDP, MWF")
        XCTAssertEqual(merged.rpe, plan.rpe)
        // load is derived: round(duration * rpe).
        XCTAssertEqual(merged.load, (61 * plan.rpe).rounded())
    }
}
