import AudioToolbox

/// Best-effort rest-over feedback for the native Manual workout. Haptics are
/// delegated through the app-wide dispatcher; the system sound is deliberately
/// small and may be suppressed by Silent mode or device settings.
@MainActor
enum ManualWorkoutRestAlert {
    static func play() {
        Haptics.shared.play(.warning)
        AudioServicesPlaySystemSound(SystemSoundID(1057))
    }
}
