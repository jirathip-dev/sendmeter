#!/usr/bin/env python3
"""#964 mutation probe: revert the classification fix in place.

Run from anywhere; operates on the lane worktree. Asserts the exact pre-fix
text exists exactly once before replacing it (a silent no-match would fake a
RED), and lets `git checkout --` + `git hash-object` prove the restore.
"""
import pathlib
import sys

ROOT = pathlib.Path("/Users/jirathip/.herdr/worktrees/sendmeter/impl-964")

# --- 1. the classification branches -----------------------------------------
friendly = ROOT / "native/SendmeterNative/Sources/Core/FriendlyError.swift"
text = friendly.read_text()

classification_branches = """        // #964: the launch-path failure families that used to collapse into
        // `.unknown`. A payload (stored or received) that this build cannot
        // decode is its own class, not an unexplained failure.
        if error is DecodingError {
            return .dataUnreadable
        }
        // GRDB's own DatabaseError carries an SQLite result code; `SQLITE_FULL`
        // is the "free up space" case the copy already covers.
        if let databaseError = error as? DatabaseError {
            return databaseError.resultCode == .SQLITE_FULL
                ? .storageFull
                : .cacheUnavailable
        }
"""
assert text.count(classification_branches) == 1, (
    f"classification branch block matched {text.count(classification_branches)} times"
)
text = text.replace(classification_branches, "")

domain_branch = """            if let classification = classification(
                forDomain: nsError.domain,
                code: nsError.code
            ) {
                return classification
            }
"""
assert text.count(domain_branch) == 1, (
    f"domain branch matched {text.count(domain_branch)} times"
)
text = text.replace(domain_branch, "")

conformances = """extension LocalCacheError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .invalidJSON:
            // A value could not be written to the cache.
            return .cacheUnavailable
        case .invalidPayload:
            // A stored payload could not be decoded back into the type this
            // build asks for — the decode family, not an unexplained failure.
            return .dataUnreadable
        }
    }
}"""
pre_fix_conformance = """extension LocalCacheError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass { .unknown }
}"""
assert text.count(conformances) == 1, "LocalCacheError conformance did not match"
text = text.replace(conformances, pre_fix_conformance)

queue_conformance = """extension DurableQueueError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .invalidDirectory:
            // #964: the queue's durable file/directory could not be used —
            // the same local-storage family as the cache.
            return .cacheUnavailable
        case .accountMismatch, .itemNotFound, .alreadyQuarantined:
            // Internal invariants, not a user-recoverable storage failure.
            return .unknown
        }
    }
}"""
assert text.count(queue_conformance) == 1, "DurableQueueError conformance did not match"
text = text.replace(
    queue_conformance,
    """extension DurableQueueError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass { .unknown }
}""",
)
friendly.write_text(text)

# --- 2. the Dashboard failure state -----------------------------------------
model = ROOT / "native/SendmeterNative/Sources/App/AppModel.swift"
model_text = model.read_text()
set_line = """                // #964: record the failure for the Dashboard before deciding
                // whether it also deserves the dismissible banner. The banner
                // is transient; this state lasts until a refresh succeeds, so
                // dismissing the banner cannot leave a blank Dashboard with no
                // explanation or retry.
                dashboardLoadFailureClass = UserFacingError.classification(for: error)
"""
assert model_text.count(set_line) == 1, (
    f"dashboard failure write matched {model_text.count(set_line)} times"
)
model_text = model_text.replace(set_line, "")
model.write_text(model_text)

print("MUTATION APPLIED: classification branches + dashboard failure state reverted")
sys.exit(0)
