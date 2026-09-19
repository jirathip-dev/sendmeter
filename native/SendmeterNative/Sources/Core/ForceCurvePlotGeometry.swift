import Foundation

/// Pure geometry for the Force duration plot (#928).
///
/// These are the exact formulas `NativeForceCurvePlot`'s Canvas used to
/// compute inline: the log-x window (`minimumSeconds`/`maximumSeconds`), the
/// headroom-scaled y-maximum, and the two fraction mappings. Extracting them
/// into Core gives the axis-typography slice a golden target — the labels may
/// grow and thin, but not one data coordinate may move.
///
/// The window deliberately spans at least 10 s so a short measured range still
/// reads as a force-duration curve, and the y-maximum keeps the same 10 kg
/// floor and 1.1 headroom as the drawn plot.
public struct ForceCurvePlotGeometry: Equatable, Sendable {
    /// Left edge of the log-x window, in seconds.
    public let minimumSeconds: Double

    /// Right edge of the log-x window, in seconds.
    public let maximumSeconds: Double

    /// Top of the y axis, in kilograms.
    public let maximumValue: Double

    public init(model: ForceCurveModel, targetBand: ForceTargetBand?) {
        let firstSeconds = model.points.first?.windowSeconds ?? 0
        let lastSeconds = model.points.last?.windowSeconds ?? 0
        let minimum = max(0.001, firstSeconds)
        let maximum = max(minimum * 1.01, max(lastSeconds, 10))
        let maximumBand = model.confidenceBand?.map(\.highKilograms).max() ?? 0
        let maximumTarget = targetBand?.highKilograms ?? 0
        self.minimumSeconds = minimum
        self.maximumSeconds = maximum
        self.maximumValue = max(
            10,
            max(model.maximumForceKilograms, max(maximumBand, maximumTarget))
        ) * 1.1
    }

    /// 0...1 fraction of the plot width for a duration on the log-x axis.
    public func xFraction(seconds: Double) -> Double {
        let minimumLog = log10(minimumSeconds)
        let maximumLog = log10(maximumSeconds)
        return (log10(max(minimumSeconds, seconds)) - minimumLog)
            / max(0.01, maximumLog - minimumLog)
    }

    /// 0...1 fraction of the plot height for a force value, measured from the
    /// bottom of the plot (0 kg is the baseline, `maximumValue` the top).
    public func yFraction(kilograms: Double) -> Double {
        max(0, kilograms) / maximumValue
    }
}
