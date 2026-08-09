import Foundation

/// Returns the honest elapsed work duration for one movement set.
///
/// A foreground tick can cross an entire inter-set rest and land in the next
/// set.  The duration for the set that just ended must stop at that set's last
/// eccentric boundary, while a stop during the set keeps the shorter wall-clock
/// duration.  The preparation countdown is excluded because `startedS` is the
/// first concentric boundary.
public func guidedMovementDurationMs(
    protocolValue: WatchForceProtocol,
    set: Int,
    startedS: Double,
    elapsedS: Double
) -> Int {
    guard protocolValue.mode == .reverseAction,
          startedS.isFinite,
          elapsedS.isFinite,
          startedS >= 0
    else { return 0 }
    let movementSegments = protocolValue.timeline.filter {
        $0.set == set && ($0.phase == .concentric || $0.phase == .eccentric)
    }
    guard let lastSegment = movementSegments.last else { return 0 }
    let setEndS = lastSegment.startS + lastSegment.durationS

    let boundedEndS = min(max(startedS, elapsedS), setEndS)
    return max(0, Int(((boundedEndS - startedS) * 1_000).rounded()))
}

/// A watch can only make an honest target claim for an explicit kilogram
/// target.  Percentage targets depend on a PR/CF/curve reference that is not
/// resolved on the watch, so they deliberately return nil.
public func fixedMovementTargetBand(
    for protocolValue: WatchForceProtocol
) -> MovementTargetBand? {
    guard let targetKg = protocolValue.targetKg,
          targetKg.isFinite,
          targetKg > 0,
          protocolValue.targetPct == nil,
          !protocolValue.targetCurve
    else { return nil }

    let toleranceValue = protocolValue.toleranceValue.isFinite
        ? max(0, protocolValue.toleranceValue)
        : 0
    let toleranceKg: Double = switch protocolValue.toleranceMode {
    case .percent:
        targetKg * toleranceValue / 100
    case .kg:
        toleranceValue
    }
    let roundedTarget = movementTimingRound(targetKg)
    return MovementTargetBand(
        kg: roundedTarget,
        lowKg: movementTimingRound(max(0, targetKg - toleranceKg)),
        highKg: movementTimingRound(targetKg + toleranceKg)
    )
}

private func movementTimingRound(_ value: Double) -> Double {
    (value * 1_000).rounded() / 1_000
}
