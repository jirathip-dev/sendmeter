import Foundation

/// One SF Symbol per product concept, shared by the watch (`WatchIconSymbol`),
/// the phone (`MainTabView`, Live Activity widgets) and the widgets so the
/// icon language reads identically everywhere (#791 W4): force = `scalemass`,
/// workout = `figure.climbing`, status = `chart.bar.fill`.
///
/// Foundation-only, so the SendmeterNativeWidgets extension compiles this
/// file by path (project.yml) rather than linking the package — the same
/// pattern as `ReadinessWidgetContract.swift`.
public enum SendmeterIconSymbol: String, Sendable, CaseIterable {
    case force = "scalemass"
    case workout = "figure.climbing"
    case status = "chart.bar.fill"
}
