import XCTest
@testable import SendLogWatch_Watch_App

final class TindeqProtocolTests: XCTestCase {
    /// Build a weight frame: [0x01][len][(float32 LE kg, uint32 LE µs) * n]
    private func weightFrame(_ pairs: [(kg: Float, us: UInt32)]) -> Data {
        var data = Data([0x01, UInt8(pairs.count * 8)])
        for p in pairs {
            withUnsafeBytes(of: p.kg.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.us.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testParsesSingleWeightSample() {
        let frame = weightFrame([(kg: 23.5, us: 1_000_000)])
        guard case .weight(let samples) = parseTindeqNotification(frame) else {
            return XCTFail("expected weight frame")
        }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].kg, 23.5, accuracy: 0.001)
        XCTAssertEqual(samples[0].us, 1_000_000)
    }

    func testParsesMultipleSamplesPerNotification() {
        let frame = weightFrame([
            (kg: 10.0, us: 0),
            (kg: 12.25, us: 12_500),
            (kg: 14.5, us: 25_000),
        ])
        guard case .weight(let samples) = parseTindeqNotification(frame) else {
            return XCTFail("expected weight frame")
        }
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[1].kg, 12.25, accuracy: 0.001)
        XCTAssertEqual(samples[2].us, 25_000)
    }

    func testLowBatteryFrame() {
        XCTAssertEqual(parseTindeqNotification(Data([0x02, 0x00])), .lowBattery)
    }

    func testResponseFrame() {
        let frame = Data([0x00, 0x02, 0xAB, 0xCD])
        guard case .response(let payload) = parseTindeqNotification(frame) else {
            return XCTFail("expected response frame")
        }
        XCTAssertEqual(payload, Data([0xAB, 0xCD]))
    }

    func testTruncatedFrameIsSafe() {
        XCTAssertEqual(parseTindeqNotification(Data([0x01])), .unknown(0xFF))
        // Length byte claims more than actually present — parse what's there
        var frame = Data([0x01, 0x10])
        frame.append(contentsOf: [UInt8](repeating: 0, count: 8))
        guard case .weight(let samples) = parseTindeqNotification(frame) else {
            return XCTFail("expected weight frame")
        }
        XCTAssertEqual(samples.count, 1)
    }

    func testUnknownTag() {
        XCTAssertEqual(parseTindeqNotification(Data([0x7F, 0x00])), .unknown(0x7F))
    }
}

// MARK: - PendingTindeqSession (issue #144)

/// Regression coverage for the end-of-session grouping bug: "Log Session"
/// used to `try? await` the network insert directly, right as the user
/// lowered their wrist — watchOS then suspended the app and froze the
/// in-flight request, so the session row (carrying the group_id every rep in
/// the connect needs) could land minutes to hours late, arriving on the phone
/// as an orphaned card over already-regrouped recordings. The fix persists a
/// `PendingTindeqSession` to `PendingSessionQueue` before any network call;
/// these tests cover the payload built at tap time (`PendingTindeqSession
/// .build`) and the round-trip encode/decode `PendingSessionQueue` relies on.
final class PendingTindeqSessionTests: XCTestCase {
    private let groupId = UUID()

    func testBuildUsesSessionStartedAtForDate() {
        // 2026-07-12 09:00 local → session runs 42 min → "now" rolls into the
        // next minute boundary but the logged date must still be the day the
        // session STARTED (mirrors Repo.makeSaveBundle's workout convention).
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 12
        comps.hour = 23
        comps.minute = 50
        let started = Calendar.gregorianLocal.date(from: comps)!
        let now = started.addingTimeInterval(42 * 60)

        let pending = PendingTindeqSession.build(
            sessionStartedAt: started,
            now: now,
            recordingCount: 11,
            rpe: 7.5,
            groupId: groupId
        )

        XCTAssertEqual(pending.date, started.localDateString)
        XCTAssertEqual(pending.durationMin, 42)
        XCTAssertEqual(pending.note, "11 recordings")
        XCTAssertEqual(pending.rpe, 7.5)
        XCTAssertEqual(pending.groupId, groupId)
    }

    func testBuildSingularRecordingNote() {
        let pending = PendingTindeqSession.build(
            sessionStartedAt: Date(),
            now: Date(),
            recordingCount: 1,
            rpe: 5,
            groupId: groupId
        )
        XCTAssertEqual(pending.note, "1 recording")
    }

    func testBuildFallsBackToNowWhenSessionStartedAtIsNil() {
        // Finish-on-disconnect (SL-58 #5) can in principle race a nil
        // sessionStartedAt — build() must not crash, and should treat the
        // session as having just started (1 min floor) rather than produce a
        // garbage duration.
        let now = Date()
        let pending = PendingTindeqSession.build(
            sessionStartedAt: nil,
            now: now,
            recordingCount: 3,
            rpe: 6,
            groupId: groupId
        )
        XCTAssertEqual(pending.durationMin, 1)
        XCTAssertEqual(pending.date, now.localDateString)
    }

    func testBuildDurationFloorsAtOneMinute() {
        let now = Date()
        let pending = PendingTindeqSession.build(
            sessionStartedAt: now, // zero elapsed
            now: now,
            recordingCount: 2,
            rpe: 5,
            groupId: groupId
        )
        XCTAssertEqual(pending.durationMin, 1)
    }

    func testBuildDurationClampsAtSixHundredMinutes() {
        let started = Date()
        let now = started.addingTimeInterval(50 * 3600) // 50 h — absurd but possible if a drop is missed
        let pending = PendingTindeqSession.build(
            sessionStartedAt: started,
            now: now,
            recordingCount: 4,
            rpe: 8,
            groupId: groupId
        )
        XCTAssertEqual(pending.durationMin, 600)
    }

    /// `PendingSessionQueue.persist`/`drain` round-trip a `PendingTindeqSession`
    /// through JSON on disk exactly like this (iso8601 dates aren't even
    /// exercised here since every field is a UUID/String/Int/Double — this
    /// guards the Codable shape itself, e.g. against an accidental snake_case
    /// `CodingKeys` mismatch that would silently drop a field on decode).
    func testPendingSessionEncodeDecodeRoundTrip() throws {
        let original = PendingTindeqSession(
            id: UUID(),
            date: "2026-07-24",
            durationMin: 17,
            rpe: 6.5,
            note: "11 recordings",
            groupId: groupId
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PendingTindeqSession.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.date, original.date)
        XCTAssertEqual(decoded.durationMin, original.durationMin)
        XCTAssertEqual(decoded.rpe, original.rpe)
        XCTAssertEqual(decoded.note, original.note)
        XCTAssertEqual(decoded.groupId, original.groupId)
    }
}

// MARK: - TindeqSalvagePolicy (issue #151)

/// A BLE drop mid-hold used to silently lose the in-flight rep — the
/// `samples` buffer survived the disconnect but nothing wrote it, and the
/// next `start()` wiped it before it could be saved. These cover the pure
/// decision of whether `TindeqManager`'s disconnect handler should salvage
/// that rep as its own recording (mirrors the web app's interruption-salvage
/// in `useTindeq.ts`/`ForceView.tsx`).
final class TindeqSalvagePolicyTests: XCTestCase {
    func testSalvagesUnplannedDropMidMeasurementWithSamples() {
        XCTAssertTrue(TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: false, wasMeasuring: true, sampleCount: 100
        ))
    }

    func testDoesNotSalvageIntentionalDisconnect() {
        XCTAssertFalse(TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: true, wasMeasuring: true, sampleCount: 100
        ))
    }

    func testDoesNotSalvageWhenNotMeasuring() {
        XCTAssertFalse(TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: false, wasMeasuring: false, sampleCount: 100
        ))
    }

    func testDoesNotSalvageWithNoSamples() {
        XCTAssertFalse(TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: false, wasMeasuring: true, sampleCount: 0
        ))
    }

    func testDoesNotSalvageWithOnlyOneSample() {
        XCTAssertFalse(TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: false, wasMeasuring: true, sampleCount: 1
        ))
    }
}
