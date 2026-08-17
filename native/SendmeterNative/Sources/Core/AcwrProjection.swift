import Foundation

/// Decay factors of the two EWMAs behind ACWR, derived from the same spans
/// `ewmaLoadState` feeds `ewma()` — `ewma` uses lambda = 2/(span+1), so the
/// acute term keeps 0.75 of itself across a zero-load day and the chronic
/// term keeps 27/29 ≈ 0.931. Never restate these as literals: the whole point
/// of deriving them from `TrainingMetrics.acuteSpanDays/chronicSpanDays` is
/// that a change to either window moves the ratio and its projection together.
public enum AcwrProjection {
    public static let lambdaAcute = 2.0 / (Double(TrainingMetrics.acuteSpanDays) + 1.0)
    public static let lambdaChronic = 2.0 / (Double(TrainingMetrics.chronicSpanDays) + 1.0)

    /// What a full rest day does to the ratio: acute decays faster than
    /// chronic, so ACWR is multiplied by (1-λa)/(1-λc) ≈ 0.806 — a flat
    /// ~19.4%/day slide that is INDEPENDENT of where you're starting from.
    /// From 1.20, two rest days already put you under 0.80.
    public static let restDayAcwrDecay = (1 - lambdaAcute) / (1 - lambdaChronic)

    /// Seven days is the honest limit. The curve assumes zero training, and
    /// every day the user deviates from that the tail past it is fiction — a
    /// 14- or 28-day version would look more informative while being less
    /// true.
    public static let projectionDays = 7

    /// The RPE the "what it would take" suggestion is priced at. Session load
    /// is `duration × RPE`, so any load splits into infinitely many
    /// (duration, RPE) pairs; fixing one makes the number concrete. 6 is a
    /// moderate, repeatable effort — it's the default RPE of most
    /// SESSION_TYPES and, unlike a hard 8, it's a session someone can actually
    /// do on a day they weren't planning to train. The card states the RPE it
    /// used rather than hiding it.
    public static let suggestionRPE = 6.0

    /// Sessions get logged in round durations, so the suggestion is quantized
    /// to the nearest 5 minutes (and never below one, which would read as
    /// advice to do a token session).
    public static let durationStepMinutes = 5

    public struct Band: Equatable, Sendable {
        public let low: Double
        public let high: Double

        public init(low: Double, high: Double) {
            self.low = low
            self.high = high
        }
    }

    /// One day of the projected curve. `dayOffset` 0 is today's actual ratio,
    /// not a projection.
    public struct ProjectedDay: Equatable, Sendable {
        public let dayOffset: Int
        public let date: String
        public let acwr: Double
        /// Where this day sits against the PHASE band (not the universal risk
        /// zone). Nil when there's no phase band to compare against.
        public let fit: PhaseFit?

        public init(dayOffset: Int, date: String, acwr: Double, fit: PhaseFit?) {
            self.dayOffset = dayOffset
            self.date = date
            self.acwr = acwr
            self.fit = fit
        }
    }

    /// A load target expressed as something you could actually do.
    public struct LoadSuggestion: Equatable, Sendable {
        public let dayOffset: Int
        public let date: String
        /// Exact AU needed on that day to land on the band floor.
        public let load: Double
        public let rpe: Double
        /// `load / rpe`, rounded to a loggable block — so `durationMin × rpe`
        /// is near, not exactly, `load`.
        public let durationMin: Int

        public init(dayOffset: Int, date: String, load: Double, rpe: Double, durationMin: Int) {
            self.dayOffset = dayOffset
            self.date = date
            self.load = load
            self.rpe = rpe
            self.durationMin = durationMin
        }
    }

    public struct Result: Equatable, Sendable {
        /// Today first (dayOffset 0, the real ratio), then one entry per
        /// projected day up to the horizon.
        public let days: [ProjectedDay]
        public let band: Band?
        /// The first projected day (offset ≥ 1) that lands under the band
        /// floor — the actionable fact. Nil when the curve stays in band all
        /// week, and also nil when there's no band at all.
        public let fallsBelow: ProjectedDay?
        /// Only when today is ABOVE the band: the first day the decay brings
        /// the ratio back into it.
        public let entersBand: ProjectedDay?
        /// What it would take to stay in band on `fallsBelow` — assuming no
        /// training on any day before it. One day at a time; it is not a plan.
        public let keepInBand: LoadSuggestion?

        public init(
            days: [ProjectedDay],
            band: Band?,
            fallsBelow: ProjectedDay?,
            entersBand: ProjectedDay?,
            keepInBand: LoadSuggestion?
        ) {
            self.days = days
            self.band = band
            self.fallsBelow = fallsBelow
            self.entersBand = entersBand
            self.keepInBand = keepInBand
        }
    }

    /// One day of the EWMA recurrence forward: the same `v*λ + ema*(1-λ)`
    /// step `ewma()` applies, with `load` as the day's value.
    public static func stepEwmaLoad(_ state: EWMALoadState, load: Double) -> EWMALoadState {
        EWMALoadState(
            acute: load * lambdaAcute + state.acute * (1 - lambdaAcute),
            chronic: load * lambdaChronic + state.chronic * (1 - lambdaChronic)
        )
    }

    public static func acwrOf(_ state: EWMALoadState) -> Double? {
        state.chronic > 0 ? state.acute / state.chronic : nil
    }

    /// Inverse of `stepEwmaLoad` + `acwrOf`: the load on the NEXT day that
    /// lands the ratio exactly on `target`. Solving
    ///   (λa·L + (1-λa)·A) / (λc·L + (1-λc)·C) = R
    /// gives L = ((1-λc)·R·C − (1-λa)·A) / (λa − λc·R).
    ///
    /// A negative result is meaningful — it means even a rest day overshoots
    /// `target` (you're above it) — so it's returned as-is and the caller
    /// decides. Nil means no load can get there: the denominator vanishes at
    /// R = λa/λc ≈ 3.63 (past which more load moves the ratio the wrong way),
    /// and a chronic term at or below zero has no ratio to aim at.
    public static func loadForRatio(_ state: EWMALoadState, target: Double) -> Double? {
        if state.chronic <= 0 { return nil }
        let denominator = lambdaAcute - lambdaChronic * target
        if denominator <= 0 { return nil }
        let numerator =
            (1 - lambdaChronic) * target * state.chronic - (1 - lambdaAcute) * state.acute
        return numerator / denominator
    }

    /// Forward ACWR curve assuming ZERO training, against the current phase's
    /// band. Deliberately not a schedule: it answers "what happens if I do
    /// nothing", plus "what would one session on the day it drops out cost me"
    /// — it does not say whether to train.
    ///
    /// Nil when there's nothing to project from: no session history
    /// (`ewmaLoadState` returns nil) or a chronic term at zero.
    public static func project(
        state: EWMALoadState?,
        band: Band?,
        horizonDays: Int = AcwrProjection.projectionDays,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Result? {
        guard let state else { return nil }
        guard let acwrToday = acwrOf(state) else { return nil }

        func fitOf(_ acwr: Double) -> PhaseFit? {
            guard let band else { return nil }
            if acwr < band.low { return .below }
            if acwr > band.high { return .above }
            return .onTarget
        }

        let today = LocalDateSupport.string(from: referenceDate, timeZone: timeZone)
        var days: [ProjectedDay] = [
            ProjectedDay(dayOffset: 0, date: today, acwr: acwrToday, fit: fitOf(acwrToday))
        ]
        // Kept alongside the ratios: the inverse needs the acute/chronic pair
        // on the day BEFORE the suggested session, which the ratio alone can't
        // recover.
        var states: [EWMALoadState] = [state]
        for offset in 1...horizonDays {
            let next = stepEwmaLoad(states[offset - 1], load: 0)
            states.append(next)
            guard let acwr = acwrOf(next) else { break }
            days.append(
                ProjectedDay(
                    dayOffset: offset,
                    date: LocalDateSupport.daysAhead(offset, from: referenceDate, timeZone: timeZone),
                    acwr: acwr,
                    fit: fitOf(acwr)
                )
            )
        }

        let projected = days.dropFirst()
        let fallsBelow = band == nil ? nil : projected.first(where: { $0.fit == .below })
        let entersBand = band == nil || days[0].fit != .above
            ? nil
            : projected.first(where: { $0.fit != .above })

        var keepInBand: LoadSuggestion? = nil
        if let band, let fallsBelow {
            let load = loadForRatio(states[fallsBelow.dayOffset - 1], target: band.low)
            if let load, load > 0 {
                keepInBand = LoadSuggestion(
                    dayOffset: fallsBelow.dayOffset,
                    date: fallsBelow.date,
                    load: load,
                    rpe: suggestionRPE,
                    durationMin: max(
                        durationStepMinutes,
                        Int((load / suggestionRPE / Double(durationStepMinutes)).rounded()) * durationStepMinutes
                    )
                )
            }
        }

        return Result(
            days: days,
            band: band,
            fallsBelow: fallsBelow,
            entersBand: entersBand,
            keepInBand: keepInBand
        )
    }
}
