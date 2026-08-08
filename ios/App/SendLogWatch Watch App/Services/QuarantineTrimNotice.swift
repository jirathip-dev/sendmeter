import Foundation

/// Durable one-shot visibility for the disk-full quarantine reclaim (#491
/// review R1): an older, repeatedly-server-rejected recording gave up its
/// stored force curve so a brand-new rep could be saved. Deliberately NOT
/// `RecordingLossNotice` — that alert says a rep "is gone", which is FALSE
/// here: the new rep was saved (that is the entire point of the reclaim) and
/// the old recording survives with its summary numbers. Telling a user they
/// lost a rep that is safely on disk is #264's dishonesty mirrored ("never
/// phrase a non-persisted recording as queued" ⇄ never phrase a persisted one
/// as lost). Same mechanism as the other notices: recorded wherever it
/// happens, consumed and presented by Home on next appearance.
enum QuarantineTrimNotice {
    private static let key = "quarantinePayloadTrimmed"
    /// `record()` runs on the queue actor while `consume()` runs on Home's
    /// main-actor lifecycle. UserDefaults makes each operation thread-safe,
    /// but the read/remove pair must be one critical section or two
    /// concurrent appearances could both present the same one-shot notice.
    private static let lock = NSLock()

    static func record() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(true, forKey: key)
    }

    static func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}
