import Foundation

/// Exponentially-weighted acute:chronic ratio (Williams et al. 2016), the
/// pure math extracted from the watch's ReadinessManager.computeACWR — the
/// data fetch (session loads from Supabase) stays in the plugin; this is the
/// unit-testable core. Mirrors the web's ewmaAcwr in src/lib/metrics.ts.
public enum Acwr {
    public static let lookbackDays = 90
    private static let lambdaAcute = 2.0 / (7.0 + 1.0)   // 7-day time constant
    private static let lambdaChronic = 2.0 / (28.0 + 1.0) // 28-day time constant

    /// `dailyLoads` is one value per day, oldest first, length `lookbackDays`.
    /// Both EWMAs are seeded with the window mean to shrink start-up bias.
    /// Returns nil when there is no load in the window.
    public static func ratio(dailyLoads: [Double]) -> Double? {
        guard dailyLoads.contains(where: { $0 != 0 }) else { return nil }
        let seed = dailyLoads.reduce(0, +) / Double(dailyLoads.count)
        var emaAcute = seed
        var emaChronic = seed
        for load in dailyLoads {
            emaAcute = load * lambdaAcute + emaAcute * (1 - lambdaAcute)
            emaChronic = load * lambdaChronic + emaChronic * (1 - lambdaChronic)
        }
        return emaChronic > 0 ? emaAcute / emaChronic : nil
    }
}
