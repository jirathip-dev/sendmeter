import Foundation

// KEEP-IN-SYNC: mirrors `src/lib/rpeDepletion.ts` — identical constants,
// identical math, identical rounding, and the SAME test vectors on both sides
// (`RPEDepletionTests.swift` ↔ `rpeDepletion.test.ts`). The watch predicts the
// RPE of a gauge session it logs itself, the phone predicts the same number
// for the same session, and the two must not drift. Only the depletion +
// mapping is duplicated: the curve FIT stays on the phone/web
// (`src/lib/force-curve.ts` — it needs the raw sample streams, which the watch
// doesn't keep), and the watch reads the fitted `cf` / `wPrime` back off
// `tindeq_tags`.
//
// The model (issue #280): the force curve is already the critical-force
// hyperbola `F = CF + W'/t`, where W' is the finite work capacity above CF —
// already an area, which is what makes it the natural basis for effort. Per
// rep, with peak force P held for T seconds:
//
//   w_i = max(0, P - CF) * T   // kg·s of W' spent, the area above CF
//   d_i = w_i / W'             // fraction of capacity, dimensionless
//
// This normalizes itself, so no arbitrary anchor is needed: a rep sitting
// exactly ON the curve for its duration has P = CF + W'/T, so (P - CF)·T = W'
// exactly, i.e. d = 1.0 — one "battery", a hang taken to failure. Session load
// is L = Σ d_i over the session's reps, each rep against ITS OWN tag's curve
// (a session can mix exercises).

/// Every tunable of the model, in one place, so it can be retuned from real
/// sessions without hunting (same convention as `Tunables.swift`).
public nonisolated enum RPEDepletionTunables {
    /// Saturation scale of the load→RPE mapping, in batteries of W'. A
    /// starting value, deliberately tunable: RPE is bounded and the second
    /// battery hurts less than the first, so L0 sets how fast that saturates.
    /// L = 1 → 4.0, L = 2 → 6.0, L = 4 → 8.2, L = 8 → 9.6.
    public static let l0: Double = 2.5
    /// Banked when NOT ONE rep of the session had a fitted curve — the same
    /// value the finish prompt defaulted to before this was predicted at all.
    /// Never blocks the save; it just means "unknown", and the session is
    /// written `rpe_confirmed = false` exactly like a prediction is.
    public static let fallbackRPE: Double = 5
}

/// KNOWN LIMITATION (accepted for now, issue #280): reps at or below CF
/// contribute ~0, so a pure sub-CF endurance session under-predicts. That is
/// inherent to W'-depletion — the whole point of CF is that work below it is
/// sustainable. Revisit with real data rather than patching it with a second
/// arbitrary term.
public nonisolated struct DepletionRep: Sendable, Equatable {
    /// Peak force of the rep (kg) — what the recording banks as `peak_kg`.
    public let peakKg: Double
    /// Hold duration in SECONDS (recordings carry `durationMs`).
    public let durationS: Double
    /// The rep's own tag's fitted curve. Nil until that tag has enough long
    /// holds to fit one; a rep without a curve contributes nothing.
    public let cf: Double?
    public let wPrime: Double?

    public init(peakKg: Double, durationS: Double, cf: Double?, wPrime: Double?) {
        self.peakKg = peakKg
        self.durationS = durationS
        self.cf = cf
        self.wPrime = wPrime
    }
}

public nonisolated struct PredictedRPE: Sendable, Equatable {
    public let rpe: Double
    /// False when the session fell back (no rep had a curve). Either way the
    /// value is written with `rpe_confirmed = false` — nobody reviewed it.
    public let fromCurve: Bool
    /// Σ d_i, nil when nothing could be measured. Exposed for notes/debugging.
    public let load: Double?
}

public nonisolated enum RPEDepletion {
    /// Fraction of W' spent by one rep, or nil when its tag has no usable
    /// curve (nothing fitted yet, or a degenerate W' ≤ 0 we can't divide by).
    public static func repDepletion(_ rep: DepletionRep) -> Double? {
        guard let cf = rep.cf, let wPrime = rep.wPrime, wPrime > 0 else { return nil }
        let durationS = max(0, rep.durationS)
        return (max(0, rep.peakKg - cf) * durationS) / wPrime
    }

    /// Σ d_i over the session, or nil when no rep had a curve to measure
    /// against — an honestly absent load, not a zero one.
    public static func sessionDepletion(_ reps: [DepletionRep]) -> Double? {
        var load = 0.0
        var measured = false
        for rep in reps {
            guard let d = repDepletion(rep) else { continue }
            measured = true
            load += d
        }
        return measured ? load : nil
    }

    /// Saturating load→RPE map: `RPE = 1 + 9·(1 - exp(-L/L0))`, rounded to 0.1
    /// and clamped to [1, 10] via `RPEQuantization.autoTracked` — these are
    /// banked predictions, not user-entered half-points.
    public static func rpeForDepletion(_ load: Double) -> Double {
        let l = max(0, load)
        let rpe = 1 + 9 * (1 - exp(-l / RPEDepletionTunables.l0))
        return RPEQuantization.autoTracked(rpe)
    }

    /// The one entry point both save paths use: never fails, never returns
    /// nothing — a missing curve must never block logging a session.
    public static func predictSessionRPE(_ reps: [DepletionRep]) -> PredictedRPE {
        guard let load = sessionDepletion(reps) else {
            return PredictedRPE(rpe: RPEDepletionTunables.fallbackRPE, fromCurve: false, load: nil)
        }
        return PredictedRPE(rpe: rpeForDepletion(load), fromCurve: true, load: load)
    }
}

/// The running Σ d_i of a gauge session, accumulated rep by rep as they're
/// saved (`TindeqManager`) — the watch never holds the whole session's
/// recordings in memory, so the sum is kept instead of the list. Pure, so the
/// accumulation itself is testable without a live manager or BLE link.
public nonisolated struct SessionDepletionAccumulator: Sendable, Equatable {
    public private(set) var load: Double = 0
    /// How many reps actually had a curve — 0 means fall back.
    public private(set) var measuredReps: Int = 0

    public init() {}

    public mutating func add(_ rep: DepletionRep) {
        guard let d = RPEDepletion.repDepletion(rep) else { return }
        measuredReps += 1
        load += d
    }

    public mutating func reset() {
        load = 0
        measuredReps = 0
    }

    /// Same contract as `RPEDepletion.predictSessionRPE`, from the running sum.
    public var predicted: PredictedRPE {
        guard measuredReps > 0 else {
            return PredictedRPE(rpe: RPEDepletionTunables.fallbackRPE, fromCurve: false, load: nil)
        }
        return PredictedRPE(rpe: RPEDepletion.rpeForDepletion(load), fromCurve: true, load: load)
    }
}
