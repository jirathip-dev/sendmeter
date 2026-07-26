import Foundation
import SendLogWatchCore

/// This install's own version + build, and the stamp that rides along on
/// every message the watch already sends to the phone (#228).
///
/// The watch app updates from TestFlight independently of the phone app, so a
/// phone on the current build can be paired with a watch several builds back —
/// which is how a pre-#208 watch kept revoking a fixed phone's session family
/// with nobody able to see it. Nothing new is sent: the live-workout beat, the
/// live-force beat and the `requestSession` ask each gain two fields.
enum WatchBuild {
    static let identity = BuildIdentity(infoDictionary: Bundle.main.infoDictionary)

    static func stamp(_ message: [String: Any]) -> [String: Any] {
        WatchBuildReport.stamped(message, with: identity)
    }
}
