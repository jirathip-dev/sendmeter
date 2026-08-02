import Foundation

/// Universal ACWR risk bands used by the web app, watch app and watch widgets.
/// The inclusive upper bounds intentionally mirror `getACWRStatus` in
/// `src/lib/metrics.ts`: 0.8 is Low, 1.3 is Optimal and 1.5 is Caution.
public enum ACWRRiskBand: String, Sendable, Equatable, CaseIterable {
    case low
    case optimal
    case caution
    case high

    public var label: String {
        switch self {
        case .low: "Low"
        case .optimal: "Optimal"
        case .caution: "Caution"
        case .high: "High"
        }
    }
}

/// Pure presentation mappings for the glanceable watch status visuals.
/// Keeping the classification and clamping out of SwiftUI makes the app and
/// every complication family agree at band edges and for out-of-range input.
public enum StatusPresentation {
    public static func readinessProgress(_ score: Int?) -> Double? {
        guard let score else { return nil }
        return min(max(Double(score) / 100, 0), 1)
    }

    public static func readinessZoneLabel(_ zone: String?) -> String? {
        switch zone?.lowercased() {
        case "recover": "Recover"
        case "maintain": "Maintain"
        case "push": "Push"
        default: nil
        }
    }

    public static func acwrRiskBand(_ value: Double?) -> ACWRRiskBand? {
        guard let value, value.isFinite else { return nil }
        if value <= 0.8 { return .low }
        if value <= 1.3 { return .optimal }
        if value <= 1.5 { return .caution }
        return .high
    }

    /// Position on the fixed 0...2 watch track, expressed as 0...1.
    public static func acwrTrackPosition(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value / 2, 0), 1)
    }
}
