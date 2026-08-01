import Foundation

/// Safety limit for a single Tindeq recording on the watch.
public enum TindeqRecordingLimit: Sendable {
    public static let maxRecordingMs: Double = 1_800_000

    public static func shouldStop(elapsedMs: Double) -> Bool {
        elapsedMs >= maxRecordingMs
    }
}
