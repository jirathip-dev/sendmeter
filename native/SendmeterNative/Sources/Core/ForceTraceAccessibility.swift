import Foundation

/// VoiceOver copy for live Force traces. The peak is passed in from the
/// existing live model so the chart summary stays useful without inventing a
/// second measurement source.
public enum ForceTraceAccessibility {
    public static func liveSummary(peakKilograms: Double?) -> String {
        guard let peakKilograms, peakKilograms.isFinite, peakKilograms > 0 else {
            return "Live force trace, no peak recorded yet"
        }

        let peak = peakKilograms.formatted(.number.precision(.fractionLength(1)))
        return "Live force trace, peak force \(peak) kilograms"
    }
}
