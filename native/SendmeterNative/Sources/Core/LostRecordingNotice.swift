import Foundation

// #632: the native mirror of the web's lost-recording reporting half — the
// "#264" section of the policy block above `persistRecording` in
// `src/lib/recordingQueue.ts`, carried out by `src/lib/lostRecordings.ts`.
//
// The web has two channels: Sentry (durable, reaches us, inert without a DSN)
// and a one-shot notice in storage (the user pulled a rep and deserves to
// know it did not survive). The native app has NO Sentry — no DSN exists in
// this target — so THE DURABLE NOTICE IS THE OUT-LOUD REPORTING. There is no
// second channel to fall back on: when the notice write itself fails (the
// same store problem that lost the recording), the user is simply never told.
// That is an accepted, explicit limitation of the single channel, not a
// missing feature — say so in code, not in silence.
//
// Semantics mirror the web's `noteLostRecordings` / `takeLostRecordingsNotice`:
//   * losses ACCUMULATE into one notice, so a protocol whose every rep failed
//     reports once with the real number;
//   * `take` reads AND clears, so the user is told exactly once (a loss that
//     happens while the app is backgrounded surfaces on the next foreground);
//   * a corrupt record reads as "nothing to say" and a fresh count starts
//     clean, never inheriting the garbage;
//   * `note` never throws — it runs on save paths that must not fail.

/// What the user finally sees (surfaced by `AppModel` on launch/foreground).
public struct LostRecordingNotice: Codable, Equatable, Sendable {
    /// Recordings lost since the notice was last shown — accumulated, so
    /// several failures report one real number.
    public var count: Int
    /// When the most recent loss happened.
    public var lastAt: Date
    /// Which loss sites contributed, deduped (`AppModel` writes
    /// "recording"/"workout"/"session" at the three discard paths).
    public var reasons: [String]

    public init(count: Int, lastAt: Date, reasons: [String]) {
        self.count = count
        self.lastAt = lastAt
        self.reasons = reasons
    }
}

public enum LostRecordingStore {
    /// The one key, mirroring the web's single `sendmeter:lost-recordings`.
    public static let defaultsKey = "sendmeter.native.lost-recordings"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Add `count` losses (from `reason`) to the pending notice. Returns
    /// whether the record actually landed — a store that refuses this too
    /// leaves the user with no signal at all, which is the single channel
    /// failing at the one moment it can't be helped. Never throws.
    @discardableResult
    public static func note(
        count: Int = 1,
        reason: String,
        in defaults: UserDefaults?,
        now: Date = Date()
    ) -> Bool {
        guard let defaults, count > 0 else { return false }
        let existing = read(in: defaults)
        let next = LostRecordingNotice(
            count: (existing?.count ?? 0) + count,
            lastAt: now,
            reasons: Array(Set((existing?.reasons ?? []) + [reason])).sorted()
        )
        guard let data = try? encoder.encode(next) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }

    /// Read the pending notice AND clear it, so it is shown exactly once. A
    /// corrupt/absent record reads as "nothing to say".
    public static func take(in defaults: UserDefaults?) -> LostRecordingNotice? {
        guard let defaults else { return nil }
        guard let notice = read(in: defaults) else { return nil }
        defaults.removeObject(forKey: defaultsKey)
        return notice
    }

    private static func read(in defaults: UserDefaults) -> LostRecordingNotice? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard let notice = try? decoder.decode(LostRecordingNotice.self, from: data) else {
            return nil
        }
        return notice.count > 0 ? notice : nil
    }
}
