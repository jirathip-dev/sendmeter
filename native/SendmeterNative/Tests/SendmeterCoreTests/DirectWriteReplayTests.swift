import XCTest
@testable import SendmeterCore

/// #916: the shared direct-write replay envelope — the persisted intent, the
/// content identity a replayed create is recognised by, the coalescing rules
/// that keep ONE operation per entity, and the durable round-trip through the
/// EXISTING `DurableQueue` (no second queue engine).
final class DirectWriteReplayTests: XCTestCase {
    // MARK: - Lost acknowledgement

    /// The create a preset/routine insert performs is not idempotent by
    /// identity: both tables mint their own `id` and the insert payload carries
    /// none. A replay must therefore recognise its own landed request from the
    /// authoritative list, not insert a second row.
    func testCreateReplayAdoptsALostAcknowledgementInsteadOfInsertingAgain() throws {
        let intended = Self.preset(name: "Max Hang 20mm")
        let landedElsewhere = Self.preset(
            name: "Max Hang 20mm",
            id: UUID(uuidString: "91600000-0000-0000-0000-0000000000bb")!
        )

        let adopted = DirectWriteReplayPolicy.alreadyApplied(
            intended: intended,
            serverValues: [Self.preset(name: "Warm-up"), landedElsewhere]
        )

        XCTAssertEqual(adopted?.id, landedElsewhere.id, "a landed create is adopted, not repeated")
    }

    func testCreateReplayInsertsWhenTheServerHasNothingLikeIt() {
        let intended = Self.preset(name: "Max Hang 20mm")

        let adopted = DirectWriteReplayPolicy.alreadyApplied(
            intended: intended,
            serverValues: [Self.preset(name: "Warm-up"), Self.preset(name: "Repeaters")]
        )

        XCTAssertNil(adopted, "an unsent create must still be sent")
    }

    // MARK: - Content identity

    func testPresetContentComparisonIgnoresTheServerMintedRowIdentity() {
        let first = Self.preset(name: "Max Hang 20mm")
        let second = Self.preset(name: "Max Hang 20mm", id: UUID())

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(
            first.hasSameMutationContent(as: second),
            "the row identity is excluded: the server mints its own id on insert"
        )
    }

    func testPresetContentComparisonDiscriminatesEverySentField() {
        let base = Self.preset(name: "Max Hang 20mm")
        let mutations: [(String, TindeqPreset)] = [
            ("name", Self.mutating(base) { $0.name = "Other" }),
            ("holdSeconds", Self.mutating(base) { $0.holdSeconds = 8 }),
            ("holdSecondsBySet", Self.mutating(base) { $0.holdSecondsBySet = [7, 7] }),
            ("repetitions", Self.mutating(base) { $0.repetitions = 7 }),
            ("sets", Self.mutating(base) { $0.sets = 4 }),
            ("restBetweenRepetitionsSeconds", Self.mutating(base) { $0.restBetweenRepetitionsSeconds = 4 }),
            ("restBetweenSetsSeconds", Self.mutating(base) { $0.restBetweenSetsSeconds = 181 }),
            ("targetKilograms", Self.mutating(base) { $0.targetKilograms = 61 }),
            ("targetPercentage", Self.mutating(base) { $0.targetPercentage = 81 }),
            ("percentageBasis", Self.mutating(base) { $0.percentageBasis = .criticalForce }),
            ("percentageStep", Self.mutating(base) { $0.percentageStep = 2.5 }),
            ("targetFromCurve", Self.mutating(base) { $0.targetFromCurve = true }),
            ("alternateSides", Self.mutating(base) { $0.alternateSides = true }),
            ("protocolMode", Self.mutating(base) { $0.protocolMode = .reverseAction }),
            ("cadenceOutSeconds", Self.mutating(base) { $0.cadenceOutSeconds = 4 }),
            ("cadenceReturnSeconds", Self.mutating(base) { $0.cadenceReturnSeconds = 5 }),
            ("toleranceMode", Self.mutating(base) { $0.toleranceMode = "absolute" }),
            ("toleranceValue", Self.mutating(base) { $0.toleranceValue = 12 }),
            ("prepareSeconds", Self.mutating(base) { $0.prepareSeconds = 9 }),
            ("setupNote", Self.mutating(base) { $0.setupNote = "chalk" }),
            ("capacityEvidence", Self.mutating(base) { $0.capacityEvidence = true }),
        ]

        for (field, mutated) in mutations {
            XCTAssertNotEqual(mutated, base, "fixture check: \(field) mutation changed the value")
            XCTAssertFalse(
                base.hasSameMutationContent(as: mutated),
                "\(field) is part of the intended mutation and must discriminate"
            )
        }
    }

    /// The zone-quality fields are transient (#902) and are never persisted by
    /// `PresetRow`/`PresetPayload`, so they must NOT make two rows differ: a
    /// replayed create would otherwise insert a duplicate for a preset the
    /// server already has.
    func testPresetContentComparisonIgnoresTransientZoneFields() {
        let base = Self.preset(name: "Max Hang 20mm")
        var transient = base
        transient.zoneQuality = .strength
        transient.zoneIntensityPercent = 75

        XCTAssertTrue(base.hasSameMutationContent(as: transient))
    }

    func testRoutineContentComparisonDiscriminatesNameAndSteps() {
        let base = Self.routine(name: "Warm-up")
        let renamed = Self.mutating(base) { $0.name = "Cool-down" }
        let resteped = Self.mutating(base) { $0.steps = [RoutineStep(label: "Other", seconds: 30)] }

        XCTAssertFalse(base.hasSameMutationContent(as: renamed))
        XCTAssertFalse(base.hasSameMutationContent(as: resteped))
        XCTAssertTrue(base.hasSameMutationContent(as: Self.routine(name: "Warm-up", id: UUID())))
    }

    /// `RoutinePayload` caps the name at 80 characters, so the comparison must
    /// mirror that cap — otherwise a long local name would never match its own
    /// round-tripped row and the replay would insert a duplicate.
    func testRoutineContentComparisonMirrorsTheServerNameCap() {
        let longName = String(repeating: "A", count: 100)
        let local = Self.routine(name: longName)
        let roundTripped = Self.routine(name: String(longName.prefix(80)), id: UUID())

        XCTAssertTrue(
            local.hasSameMutationContent(as: roundTripped),
            "the server's own name cap must not make the row unrecognisable"
        )
        XCTAssertTrue(
            local.hasSameMutationContent(as: Self.routine(name: longName, id: UUID())),
            "and a step's local-only id must not either"
        )
    }

    // MARK: - Coalescing

    func testCoalesceKeepsOneOperationPerEntity() {
        // A newer mutation always wins the CONTENT; the operation is what
        // decides whether a replay can still materialize the entity.
        XCTAssertEqual(
            DirectWriteReplayPolicy.coalesce(pending: .create, incoming: .update),
            .create,
            "an update cannot PATCH a row the create has not inserted yet"
        )
        XCTAssertEqual(
            DirectWriteReplayPolicy.coalesce(pending: .update, incoming: .create),
            .update,
            "a second create must not insert a second row for one identity"
        )
        XCTAssertEqual(DirectWriteReplayPolicy.coalesce(pending: .create, incoming: .delete), .delete)
        XCTAssertEqual(DirectWriteReplayPolicy.coalesce(pending: .update, incoming: .delete), .delete)
        XCTAssertEqual(DirectWriteReplayPolicy.coalesce(pending: .create, incoming: .create), .create)
        XCTAssertEqual(DirectWriteReplayPolicy.coalesce(pending: .update, incoming: .update), .update)
        XCTAssertNil(
            DirectWriteReplayPolicy.coalesce(pending: .delete, incoming: .create),
            "a removed entity must not be resurrected"
        )
        XCTAssertNil(
            DirectWriteReplayPolicy.coalesce(pending: .delete, incoming: .update),
            "a removed entity must not be resurrected"
        )
    }

    // MARK: - Legacy cache-only rows

    func testLegacyOperationIsDerivedFromProvableEvidence() {
        XCTAssertEqual(
            DirectWriteReplayPolicy.legacyOperation(isTombstoned: true, serverHasEntity: false),
            .delete,
            "a pending tombstone is a local delete the server never confirmed"
        )
        XCTAssertEqual(
            DirectWriteReplayPolicy.legacyOperation(isTombstoned: true, serverHasEntity: true),
            .delete
        )
        XCTAssertEqual(
            DirectWriteReplayPolicy.legacyOperation(isTombstoned: false, serverHasEntity: true),
            .update,
            "a live row the server still has under the same id is an update"
        )
        XCTAssertEqual(
            DirectWriteReplayPolicy.legacyOperation(isTombstoned: false, serverHasEntity: false),
            .create,
            "a live row the server does not have is a create (checked for content before it is sent)"
        )
    }

    // MARK: - Queue durability (the existing engine)

    /// The envelope must survive process death in the EXISTING `DurableQueue`:
    /// a fresh queue instance over the same file must return the account, the
    /// entity identity, the operation and the immutable intended mutation.
    func testDirectWriteIntentSurvivesAFreshQueueInstanceOverTheSameFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let preset = Self.preset(name: "Relaunch Me")
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.preset(preset),
            operation: .create,
            mutation: preset
        )

        let queue = try DurableQueue<TestDirectWritePayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
        let enqueued = try await queue.enqueue(
            DurableQueueItem(
                id: preset.id,
                accountUserID: user,
                terminalKey: preset.id,
                payload: .preset(intent)
            )
        )
        XCTAssertTrue(enqueued)

        // Process death: nothing in memory survives; only the file does.
        let relaunched = try DurableQueue<TestDirectWritePayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
        let restored = await relaunched.item(id: preset.id, accountUserID: user)

        guard case let .preset(restoredIntent)? = restored?.payload else {
            return XCTFail("the direct-write intent did not survive the relaunch")
        }
        XCTAssertEqual(restored?.accountUserID, user, "the intent is account-scoped")
        XCTAssertEqual(restoredIntent.entityID, CacheEntityID.preset(preset))
        XCTAssertEqual(restoredIntent.operation, .create)
        XCTAssertEqual(restoredIntent.operationID, intent.operationID, "the operation identity is stable")
        XCTAssertEqual(
            restoredIntent.intendedAt.timeIntervalSince1970,
            intent.intendedAt.timeIntervalSince1970,
            accuracy: 1,
            "the intent timestamp survives the queue's whole-second JSON timestamps"
        )
        XCTAssertEqual(restoredIntent.mutation, preset, "the intended mutation is immutable")
    }

    func testRoutineIntentRoundTripsThroughTheQueueToo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let routine = Self.routine(name: "Repeaters")
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.routine(routine),
            operation: .update,
            mutation: routine
        )

        let queue = try DurableQueue<TestDirectWritePayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
        _ = try await queue.enqueue(
            DurableQueueItem(
                id: routine.id,
                accountUserID: user,
                terminalKey: routine.id,
                payload: .routine(intent)
            )
        )
        let relaunched = try DurableQueue<TestDirectWritePayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
        let restored = await relaunched.item(id: routine.id, accountUserID: user)

        guard case let .routine(restoredIntent)? = restored?.payload else {
            return XCTFail("the routine intent did not survive the relaunch")
        }
        XCTAssertEqual(restoredIntent.operation, .update)
        // `RoutineStep.id` is local-only, so the round-tripped content is
        // compared by the schema's own fields.
        XCTAssertEqual(restoredIntent.mutation?.name, routine.name)
        XCTAssertTrue(
            try XCTUnwrap(restoredIntent.mutation).hasSameMutationContent(as: routine),
            "the intended routine mutation is immutable across the relaunch"
        )
        let foreignAccountItem = await relaunched.item(id: routine.id, accountUserID: UUID())
        XCTAssertNil(foreignAccountItem, "the queue is account-scoped: another account sees nothing")
    }

    // MARK: - Envelope encoding

    func testIntentEncodesItsIdentityOperationAndContent() throws {
        let preset = Self.preset(name: "Encoded")
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.preset(preset),
            operation: .delete,
            mutation: preset
        )

        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(DirectWriteIntent<TindeqPreset>.self, from: data)

        XCTAssertEqual(decoded, intent)
    }

    /// A queue file whose envelope lost its intended mutation cannot be
    /// replayed; it must be classified as a payload problem so the existing
    /// quarantine keeps it recoverable instead of retrying for ever.
    func testMissingIntendedMutationIsAPermanentRejection() {
        XCTAssertEqual(
            DirectWriteReplayError.missingIntendedMutation.rejectionClass,
            .permanent
        )
    }

    // MARK: - Fixtures

    private static func preset(
        name: String,
        id: UUID = UUID()
    ) -> TindeqPreset {
        TindeqPreset(
            id: id,
            name: name,
            holdSeconds: 7,
            holdSecondsBySet: [7],
            repetitions: 6,
            sets: 3,
            restBetweenRepetitionsSeconds: 3,
            restBetweenSetsSeconds: 180,
            targetKilograms: 60,
            targetPercentage: 80,
            percentageBasis: .personalRecord,
            percentageStep: 2,
            targetFromCurve: false,
            alternateSides: false,
            protocolMode: .hold,
            cadenceOutSeconds: 3,
            cadenceReturnSeconds: 3,
            toleranceMode: "percent",
            toleranceValue: 10,
            prepareSeconds: 5,
            setupNote: "",
            capacityEvidence: false
        )
    }

    private static func routine(
        name: String,
        id: UUID = UUID()
    ) -> RoutinePreset {
        RoutinePreset(id: id, name: name, steps: [RoutineStep(label: "Hang", seconds: 20)])
    }

    private static func mutating(
        _ preset: TindeqPreset,
        _ change: (inout TindeqPreset) -> Void
    ) -> TindeqPreset {
        var copy = preset
        change(&copy)
        return copy
    }

    private static func mutating(
        _ routine: RoutinePreset,
        _ change: (inout RoutinePreset) -> Void
    ) -> RoutinePreset {
        var copy = routine
        change(&copy)
        return copy
    }
}

/// The app's `PendingWrite` shape for the direct-write slice: the queue stays
/// generic, so the test payload mirrors exactly what `AppModel` persists.
private enum TestDirectWritePayload: Codable, Equatable, Sendable {
    case preset(DirectWriteIntent<TindeqPreset>)
    case routine(DirectWriteIntent<RoutinePreset>)
}
