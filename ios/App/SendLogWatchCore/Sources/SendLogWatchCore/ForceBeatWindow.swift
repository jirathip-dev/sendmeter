import Foundation

/// The trailing window of samples a live-force beat (SL-87/SL-95) sends over
/// WatchConnectivity. Pure so it's unit-testable without WatchConnectivity —
/// see `TindeqManager.pushForceBeat()` (issue #148: a fixed 3 s window left a
/// permanent gap in the phone's mirror sparkline whenever WC reachability
/// flapped for longer than that between beats). `sinceT` backfills exactly
/// what the last successful beat didn't cover, capped so a long gap still
/// sends a bounded payload.
public enum ForceBeatWindow {
    public static func window(
        samples: [(t: Double, kg: Double)],
        sinceT: Double?,
        capMs: Double = 15_000,
        maxPoints: Int = 40
    ) -> [[Double]] {
        guard let last = samples.last else { return [] }
        let bound = max(sinceT ?? -.infinity, last.t - capMs)
        let recent = samples.filter { $0.t > bound }
        guard !recent.isEmpty else { return [] }
        let step = max(1, recent.count / maxPoints)
        var out: [[Double]] = []
        var i = 0
        while i < recent.count {
            let s = recent[i]
            out.append([s.t.rounded(), (s.kg * 100).rounded() / 100])
            i += step
        }
        return out
    }
}
