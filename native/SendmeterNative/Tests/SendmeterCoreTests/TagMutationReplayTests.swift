import XCTest
@testable import SendmeterCore

/// Pins the #918 tag-registry mutation rules: the stable queue identity a tag
/// name maps to, the composition of a newer mutation onto a still-pending one,
/// and the end-state proof a replay is allowed to confirm.
///
/// The rules are matched to what the repository and the DB actually do:
/// `rename_tindeq_tag` repoints every recording carrying the old name, drops the
/// old registry row, and only carries a row across when the old name had one;
/// `setTagHidden` upserts `(name, hidden)` and never touches the recordings or
/// the side mode.
final class TagMutationReplayTests: XCTestCase {
    private func recording(_ id: UUID, tag: String) -> TindeqRecording {
        TindeqRecording(
            id: id,
            recordedAt: Date(),
            durationMilliseconds: 1_000,
            peakKilograms: 20,
            averageKilograms: 15,
            sampleCount: 1,
            note: "",
            tag: tag,
            side: .unspecified,
            groupID: nil
        )
    }

    private func metadata(_ name: String, hidden: Bool) -> TagMetadata {
        TagMetadata(name: name, hidden: hidden)
    }

    // MARK: - Stable, name-scoped queue identity

    func testQueueIdentityIsStableForAName() {
        let first = TagMutationIdentity.queueItemID(for: "half crimp")
        let second = TagMutationIdentity.queueItemID(for: "half crimp")
        XCTAssertEqual(first, second, "the same name must map to the same identity")
        XCTAssertEqual(
            first,
            TagMutationIdentity.queueItemID(for: "  half crimp  "),
            "the registry trims a tag name, so the identity must not depend on padding"
        )
        XCTAssertNotEqual(
            first,
            TagMutationIdentity.queueItemID(for: "Half Crimp"),
            "tag names are matched exactly — case is part of the identity"
        )
        XCTAssertNotEqual(first, TagMutationIdentity.queueItemID(for: "sloper"))
        XCTAssertNotEqual(
            first,
            TagMutationIdentity.queueItemID(for: ""),
            "an empty name is still distinguishable from a real one"
        )
    }

    /// The literal answer, so a future change to the mapping is a deliberate,
    /// visible one: a relaunch (or a second build) has to find the SAME pending
    /// item by name.
    func testQueueIdentityIsFrozenForKnownNames() {
        XCTAssertEqual(
            TagMutationIdentity.queueItemID(for: "half crimp").uuidString.lowercased(),
            "591b7da4-84eb-594a-8d5f-6a507c6cf091"
        )
        XCTAssertEqual(
            TagMutationIdentity.queueItemID(for: "Repeaters").uuidString.lowercased(),
            "c51c5538-abcc-5d38-bb10-321644131f62"
        )
        XCTAssertEqual(
            TagMutationIdentity.queueItemID(for: "").uuidString.lowercased(),
            "f643e047-ee27-595c-a6af-78e24c1126b3"
        )
    }

    func testQueueIdentityCarriesUUIDVersion5AndVariantBits() {
        let bytes = withUnsafeBytes(of: TagMutationIdentity.queueItemID(for: "x").uuid) {
            Array($0)
        }
        XCTAssertEqual(bytes[6] >> 4, 0x5, "UUIDv5 version nibble")
        XCTAssertEqual(bytes[8] >> 6, 0b10, "RFC 4122 variant bits")
    }

    func testIntentQueueIdentityFollowsTheNameItStartedUnder() {
        let intent = TagMutationIntent(knownNames: ["A", "B"], renamedTo: "C")
        XCTAssertEqual(intent.tagName, "B", "the newest name is the current one")
        XCTAssertEqual(intent.originName, "A")
        XCTAssertEqual(intent.finalName, "C")
        XCTAssertEqual(
            intent.queueIdentity,
            TagMutationIdentity.queueItemID(for: "A"),
            "a chained rename keeps the identity of the tag it started as"
        )
        XCTAssertEqual(intent.retiredNames, ["A", "B"])
    }

    func testVisibilityOnlyIntentRetiresNoNames() {
        let intent = TagMutationIntent(knownNames: ["A"], hidden: true)
        XCTAssertEqual(intent.finalName, "A")
        XCTAssertTrue(intent.retiredNames.isEmpty)
        XCTAssertNil(
            TagMutationReplayPolicy.repointSource(
                intent: intent,
                serverTags: [metadata("A", hidden: false)],
                serverRecordings: []
            ),
            "a visibility change never repoints recordings"
        )
    }

    // MARK: - Composing a newer mutation onto a pending one

    func testReplacingChainsARenameOntoThePendingRename() {
        let pending = TagMutationIntent(
            knownNames: ["A"],
            renamedTo: "B",
            operationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        let incoming = TagMutationIntent(knownNames: ["B"], renamedTo: "C")
        let composed = TagMutationReplayPolicy.replacing(pending: pending, incoming: incoming)
        XCTAssertEqual(composed.knownNames, ["A", "B"])
        XCTAssertEqual(composed.renamedTo, "C", "the newest rename is the word that counts")
        XCTAssertEqual(composed.finalName, "C")
        XCTAssertEqual(
            composed.operationID,
            pending.operationID,
            "the operation identity survives the replacement"
        )
        XCTAssertEqual(composed.intendedAt, pending.intendedAt)
        XCTAssertEqual(composed.queueIdentity, pending.queueIdentity)
    }

    func testReplacingKeepsTheRenameWhenAVisibilityChangeArrives() {
        let pending = TagMutationIntent(knownNames: ["A"], renamedTo: "B")
        let incoming = TagMutationIntent(knownNames: ["B"], hidden: true)
        let composed = TagMutationReplayPolicy.replacing(pending: pending, incoming: incoming)
        XCTAssertEqual(composed.knownNames, ["A", "B"])
        XCTAssertEqual(composed.renamedTo, "B", "the pending rename is never dropped")
        XCTAssertEqual(composed.hidden, true)
        XCTAssertEqual(composed.finalName, "B")
    }

    /// The repository's own rule: a rename does not carry `hidden` across (the
    /// DB function only carries `side_mode`), so a rename that supersedes a
    /// pending hide leaves the tag visible.
    func testReplacingLetsARenameClearAPendingVisibilityIntent() {
        let pending = TagMutationIntent(knownNames: ["A"], hidden: true)
        let incoming = TagMutationIntent(knownNames: ["A"], renamedTo: "B")
        let composed = TagMutationReplayPolicy.replacing(pending: pending, incoming: incoming)
        XCTAssertEqual(composed.knownNames, ["A"])
        XCTAssertEqual(composed.renamedTo, "B")
        XCTAssertNil(composed.hidden)
    }

    func testReplacingKeepsTheNewestVisibilityOnTheSameName() {
        let pending = TagMutationIntent(knownNames: ["A"], hidden: true)
        let incoming = TagMutationIntent(knownNames: ["A"], hidden: false)
        let composed = TagMutationReplayPolicy.replacing(pending: pending, incoming: incoming)
        XCTAssertEqual(composed.knownNames, ["A"])
        XCTAssertEqual(composed.hidden, false)
        XCTAssertNil(composed.renamedTo)
    }

    func testReplacingUnionsTheReferencesItCarries() {
        let first = UUID()
        let second = UUID()
        let pending = TagMutationIntent(knownNames: ["A"], renamedTo: "B", recordingIDs: [first])
        let incoming = TagMutationIntent(knownNames: ["B"], hidden: true, recordingIDs: [first, second])
        let composed = TagMutationReplayPolicy.replacing(pending: pending, incoming: incoming)
        XCTAssertEqual(composed.recordingIDs, [first, second])
    }

    // MARK: - The end state a replay may confirm

    func testRenameIsCompleteOnlyWhenEveryReferenceCarriesTheNewName() {
        let first = UUID()
        let second = UUID()
        let intent = TagMutationIntent(
            knownNames: ["A"],
            renamedTo: "B",
            recordingIDs: [first, second]
        )
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [],
                serverRecordings: [recording(first, tag: "B"), recording(second, tag: "A")]
            ),
            "AC2: a rename that would leave a reference behind is not complete"
        )
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [],
                serverRecordings: [recording(first, tag: "B"), recording(second, tag: "B")]
            )
        )
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [],
                serverRecordings: [recording(first, tag: "B")],
                // `second` is gone from the server: a removal is a later word
                // than this rename, so it is not a lost reference.
            ),
            "an explicitly removed recording is not a lost reference"
        )
    }

    func testRenameIsNotCompleteWhileTheOldRegistryRowSurvives() {
        let intent = TagMutationIntent(knownNames: ["A"], renamedTo: "B")
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("A", hidden: true)],
                serverRecordings: []
            ),
            "the DB function drops the old row — a surviving row means it did not run"
        )
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("B", hidden: false)],
                serverRecordings: []
            )
        )
    }

    func testChainedRenameIsNotCompleteWhileAnyKnownOldNameSurvives() {
        let intent = TagMutationIntent(knownNames: ["A", "B"], renamedTo: "C")
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("B", hidden: true)],
                serverRecordings: []
            )
        )
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("A", hidden: false)],
                serverRecordings: []
            )
        )
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("C", hidden: false), metadata("Other", hidden: true)],
                serverRecordings: []
            ),
            "unrelated registry rows are never this mutation's business"
        )
    }

    func testVisibilityIsCompleteOnlyWithTheIntendedRow() {
        let hide = TagMutationIntent(knownNames: ["A"], hidden: true)
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: hide,
                serverTags: [],
                serverRecordings: []
            ),
            "the upsert creates the row, so a missing row means it did not land"
        )
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: hide,
                serverTags: [metadata("A", hidden: false)],
                serverRecordings: []
            )
        )
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: hide,
                serverTags: [metadata("A", hidden: true)],
                serverRecordings: []
            )
        )
        let unhide = TagMutationIntent(knownNames: ["A"], hidden: false)
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: unhide,
                serverTags: [metadata("A", hidden: false)],
                serverRecordings: []
            )
        )
    }

    func testRenameAndVisibilityIsCompleteOnlyWhenBothHalvesAgree() {
        let intent = TagMutationIntent(knownNames: ["A", "B"], renamedTo: "B", hidden: true)
        XCTAssertFalse(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("B", hidden: false)],
                serverRecordings: []
            ),
            "the rename landed but the visibility did not"
        )
        XCTAssertTrue(
            TagMutationReplayPolicy.isComplete(
                intent: intent,
                serverTags: [metadata("B", hidden: true)],
                serverRecordings: []
            )
        )
    }

    // MARK: - The name a replay repoints FROM

    func testRepointSourceFollowsTheServerNotTheIntent() {
        let id = UUID()
        XCTAssertEqual(
            TagMutationReplayPolicy.repointSource(
                intent: TagMutationIntent(knownNames: ["A"], renamedTo: "B", recordingIDs: [id]),
                serverTags: [],
                serverRecordings: [recording(id, tag: "A")]
            ),
            "A",
            "the rename never landed: it repoints from the name the server serves"
        )
        XCTAssertNil(
            TagMutationReplayPolicy.repointSource(
                intent: TagMutationIntent(knownNames: ["A"], renamedTo: "B", recordingIDs: [id]),
                serverTags: [],
                serverRecordings: [recording(id, tag: "B")]
            ),
            "the references already carry the intended name: there is nothing to send"
        )
        XCTAssertNil(
            TagMutationReplayPolicy.repointSource(
                intent: TagMutationIntent(knownNames: ["A"], renamedTo: "A", recordingIDs: [id]),
                serverTags: [],
                serverRecordings: [recording(id, tag: "A")]
            ),
            "a rename to the name the records already carry is never sent"
        )
    }

    func testRepointSourceUsesARegistryRowWhenTheTagHasNoRecordings() {
        XCTAssertEqual(
            TagMutationReplayPolicy.repointSource(
                intent: TagMutationIntent(knownNames: ["A"], renamedTo: "B"),
                serverTags: [metadata("A", hidden: true)],
                serverRecordings: []
            ),
            "A",
            "a row still has to be moved by the rename"
        )
        XCTAssertNil(
            TagMutationReplayPolicy.repointSource(
                intent: TagMutationIntent(knownNames: ["A"], renamedTo: "B"),
                serverTags: [],
                serverRecordings: []
            )
        )
    }

    func testChainedRoundTripRepointsFromWhicheverNameTheServerServes() {
        let id = UUID()
        let roundTrip = TagMutationIntent(
            knownNames: ["A", "B"],
            renamedTo: "A",
            recordingIDs: [id]
        )
        XCTAssertNil(
            TagMutationReplayPolicy.repointSource(
                intent: roundTrip,
                serverTags: [],
                serverRecordings: [recording(id, tag: "A")]
            ),
            "nothing landed: the tag is already where the user left it"
        )
        XCTAssertEqual(
            TagMutationReplayPolicy.repointSource(
                intent: roundTrip,
                serverTags: [],
                serverRecordings: [recording(id, tag: "B")]
            ),
            "B",
            "the first rename landed: the second one repoints it back"
        )
    }

    // MARK: - Durability of the envelope

    func testIntentRoundTripsThroughTheQueueEncoding() throws {
        let intent = TagMutationIntent(
            knownNames: ["A", "B"],
            renamedTo: "C",
            hidden: true,
            recordingIDs: [UUID(), UUID()]
        )
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(TagMutationIntent.self, from: data)
        XCTAssertEqual(decoded, intent)
    }

    func testIntentDecodesAQueueEntryWithNoReferences() throws {
        let json = """
        {"knownNames":["Repeaters"],"renamedTo":"Repeaters 5.0","operationID":"11111111-1111-4111-8111-111111111111","intendedAt":0,"recordingIDs":[]}
        """
        let decoded = try JSONDecoder().decode(
            TagMutationIntent.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.tagName, "Repeaters")
        XCTAssertEqual(decoded.finalName, "Repeaters 5.0")
        XCTAssertNil(decoded.hidden)
        XCTAssertTrue(decoded.recordingIDs.isEmpty)
    }
}
