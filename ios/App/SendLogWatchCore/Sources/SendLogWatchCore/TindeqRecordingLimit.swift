import Foundation

/// Safety limit for a single Tindeq recording on the watch.
public enum TindeqRecordingLimit: Sendable {
    public static let maxRecordingMs: Double = 1_800_000
    /// Movement sets are one continuous recording. Keep one second of
    /// headroom when normalizing legacy presets so a sample arriving exactly
    /// at the BLE cap cannot race the guided boundary handler.
    public static let maxMovementSetS: Double = maxRecordingMs / 1_000 - 1

    public static let minMovementCadenceS: Double = 0.5
    public static let maxMovementCadenceS: Double = 30
    public static let maxMovementReps: Int = 50

    public static func maxMovementReps(
        cadenceOutS: Double,
        cadenceReturnS: Double
    ) -> Int {
        let out = boundedMovementCadence(cadenceOutS)
        let back = boundedMovementCadence(cadenceReturnS)
        let cycleS = out + back
        return max(1, min(maxMovementReps, Int(floor(maxMovementSetS / cycleS))))
    }

    private static func boundedMovementCadence(_ value: Double) -> Double {
        guard value.isFinite else { return 3 }
        return min(max(value, minMovementCadenceS), maxMovementCadenceS)
    }

    public static func shouldStop(elapsedMs: Double) -> Bool {
        elapsedMs >= maxRecordingMs
    }
}
