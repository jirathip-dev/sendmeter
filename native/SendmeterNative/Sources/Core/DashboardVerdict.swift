import Foundation

/// #1028 E / #1022: ONE clear Dashboard verdict — readiness × load ratio.
///
/// Every cell of the table has its own copy, recovery advice appears once,
/// and the load line never shows an unqualified "Under-training" next to a
/// "Recover" verdict (low readiness explains the low load; it is not a call
/// to train more).
///
///                    load: none   under(<0.8)   optimal(0.8–1.3)   high(>1.3)
///   recover  (<40)   Recover      Recover       Recover            Recover · deload
///   maintain (40–70) Maintain     Maintain+     Maintain           Maintain · hold load
///   push     (>70)   Train        Build         Train              Train · hold load
public enum DashboardVerdict {
    public enum ReadinessBand: String, CaseIterable, Sendable {
        case recover, maintain, push

        public init(score: Int) {
            if score < 40 { self = .recover } else if score > 70 { self = .push } else { self = .maintain }
        }
    }

    public enum LoadBand: String, CaseIterable, Sendable {
        case none, under, optimal, high

        public init(ratio: Double?) {
            guard let ratio, ratio.isFinite else { self = .none; return }
            if ratio < 0.8 { self = .under } else if ratio <= 1.3 { self = .optimal } else { self = .high }
        }
    }

    public struct Copy: Equatable, Sendable {
        /// The one verdict line (headline).
        public let headline: String
        /// The qualified load line, or nil when there is no ratio yet.
        public let loadLine: String?
    }

    public static func copy(readiness: Int, ratio: Double?) -> Copy {
        let band = ReadinessBand(score: readiness)
        let load = LoadBand(ratio: ratio)
        let ratioText = ratio.map { "Load ratio " + $0.formatted(.number.precision(.fractionLength(2))) }
        func line(_ qualifier: String) -> String? { ratioText.map { "\($0) · \(qualifier)" } }

        switch (band, load) {
        case (.recover, .none):
            return Copy(headline: "Recover today — easy movement only.", loadLine: nil)
        case (.recover, .under):
            return Copy(headline: "Recover today — easy movement only.", loadLine: line("light week, expected at low readiness"))
        case (.recover, .optimal):
            return Copy(headline: "Recover today — your load is fine, your body isn't.", loadLine: line("on track"))
        case (.recover, .high):
            return Copy(headline: "Recover and deload — readiness and load both say rest.", loadLine: line("high, ease off this week"))
        case (.maintain, .none):
            return Copy(headline: "Maintain — train, but keep one rep in reserve.", loadLine: nil)
        case (.maintain, .under):
            return Copy(headline: "Maintain — a normal session is fine; add volume gradually.", loadLine: line("below your usual, build back steadily"))
        case (.maintain, .optimal):
            return Copy(headline: "Maintain — train, but keep one rep in reserve.", loadLine: line("on track"))
        case (.maintain, .high):
            return Copy(headline: "Maintain — hold intensity, don't add volume.", loadLine: line("high, hold this week's load"))
        case (.push, .none):
            return Copy(headline: "Ready to train — use the planned block intensity.", loadLine: nil)
        case (.push, .under):
            return Copy(headline: "Ready to build — a good day to add volume.", loadLine: line("below your usual, room to build"))
        case (.push, .optimal):
            return Copy(headline: "Ready to train — use the planned block intensity.", loadLine: line("on track"))
        case (.push, .high):
            return Copy(headline: "Ready, but hold load — keep volume where it is.", loadLine: line("high, don't add volume"))
        }
    }
}

/// #1028 E / #1023: the Readiness Trend's sparse state. Below the threshold
/// the chart is replaced by one line and a button into the existing
/// recovery-inputs sheet.
public enum ReadinessTrendDensity {
    /// Scored days in the 14-day window below which a chart reads as noise.
    public static let minimumScoredDays = 5

    public static func isSparse(scoredDaysInWindow: Int) -> Bool {
        scoredDaysInWindow < minimumScoredDays
    }

    public static func sparseLine(scoredDaysInWindow: Int) -> String {
        switch scoredDaysInWindow {
        case 0: return "No readiness scores in the last 14 days yet."
        case 1: return "1 readiness score in the last 14 days — the trend needs a few more."
        default: return "\(scoredDaysInWindow) readiness scores in the last 14 days — the trend needs a few more."
        }
    }

    public static let sparseAction = "Check recovery inputs"
}
