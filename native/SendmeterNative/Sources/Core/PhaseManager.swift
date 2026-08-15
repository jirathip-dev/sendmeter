import Foundation

public enum PhaseMutation: Equatable, Sendable {
    case create(phase: PhaseID, startedOn: String)
    case delete(periodID: UUID)
    case updatePhase(periodID: UUID, phase: PhaseID)
    case close(periodID: UUID, endedOn: String)
    case reopen(periodID: UUID)
    case updateSettings(phase: PhaseID, startedOn: String)
}

public struct PhaseTransitionPlan: Equatable, Sendable {
    public let mutations: [PhaseMutation]

    public init(mutations: [PhaseMutation]) {
        self.mutations = mutations
    }
}

public enum PhaseTransitionPlanner {
    /// Mirrors the established same-day phase behavior: no 1-day slivers,
    /// switching back to the phase just left reopens the previous period, and
    /// settings always point at the canonical open period.
    public static func plan(
        periods: [PhasePeriod],
        newPhase: PhaseID,
        today: String
    ) -> PhaseTransitionPlan {
        let open = periods.first(where: { $0.endedOn == nil })
        guard let open else {
            return PhaseTransitionPlan(mutations: [
                .create(phase: newPhase, startedOn: today),
                .updateSettings(phase: newPhase, startedOn: today)
            ])
        }

        if open.phase == newPhase {
            return PhaseTransitionPlan(mutations: [])
        }

        if open.startedOn == today {
            let previous = periods
                .filter { $0.endedOn != nil }
                .sorted { ($0.endedOn ?? "") > ($1.endedOn ?? "") }
                .first

            if let previous,
               previous.phase == newPhase,
               previous.endedOn == today {
                return PhaseTransitionPlan(mutations: [
                    .delete(periodID: open.id),
                    .reopen(periodID: previous.id),
                    .updateSettings(phase: newPhase, startedOn: previous.startedOn)
                ])
            }

            return PhaseTransitionPlan(mutations: [
                .updatePhase(periodID: open.id, phase: newPhase),
                .updateSettings(phase: newPhase, startedOn: open.startedOn)
            ])
        }

        return PhaseTransitionPlan(mutations: [
            .close(periodID: open.id, endedOn: today),
            .create(phase: newPhase, startedOn: today),
            .updateSettings(phase: newPhase, startedOn: today)
        ])
    }
}
