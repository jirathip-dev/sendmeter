import Foundation

/// Deterministic motion values shared by the Force phase surfaces and the
/// manual-workout hero action. SwiftUI owns the actual `Animation` values;
/// keeping the policy here makes the accessibility contract testable without
/// importing the App target.
public enum ForceMotionPolicy {
    /// The phase tint should settle in roughly the same time as the web's
    /// 300 ms transition, while the spring keeps a phase flip from feeling
    /// like a hard color replacement.
    public static let phaseResponseSeconds = 0.3
    public static let phaseDampingFraction = 0.82

    /// The BOULDER/DONE hero gets a small, deliberate press pulse rather than
    /// changing its layout or interaction semantics.
    public static let heroActionScale = 1.05
    public static let heroActionResponseSeconds = 0.18
    public static let heroActionDampingFraction = 0.78

    public static func phaseTransitionDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : phaseResponseSeconds
    }

    public static func heroScale(isPressed: Bool, reduceMotion: Bool) -> Double {
        isPressed && !reduceMotion ? heroActionScale : 1
    }
}
