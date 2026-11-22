import Foundation
import XCTest

final class UserFacingCopyDenylistTests: XCTestCase {
    private let deniedTerms = [
        "immutable", "metadata", "atomically", "linked session", "durable",
        "quarantin", "upload path", "upload queue", "relay", "server",
        "cached", "healthkit", "buffer", "this build", "evidence set"
    ]

    private let sourceRoots = [
        "Sources",
        "../../ios/App/SendLogWatch Watch App",
        "../../ios/App/SendLogWatchWidgets",
        "../../ios/App/SendLogWatchCore/Sources"
    ]

    private let nonCopyLineMarkers = [
        "Logger", "log.", ".log(", "logger", "os_log", "print(", "precondition",
        "assert", "fatalError", "NSLocalizedDescriptionKey", "recordCacheFailure",
        "onFailure(", "sql:", ".select(", "recordAuthEvent", "accessibilityIdentifier",
        "forKey", "UserDefaults", "rawValue", "DispatchQueue", "Notification.Name"
    ]

    private let technicalOnly: [(file: String, prefix: String)] = [
        ("Features/Settings/SettingsView.swift", "Server code"),
        ("Services/LiveWorkoutTerminalRetry.swift", "terminal live_workouts")
    ]

    func testPhoneAndWatchCopyCarriesNoImplementationTerms() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var scannedFiles = 0
        var hits: [String] = []
        for root in sourceRoots {
            let rootURL = packageRoot.appendingPathComponent(root).standardizedFileURL
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: rootURL.path))
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                let text = try String(contentsOf: rootURL.appendingPathComponent(relative), encoding: .utf8)
                scannedFiles += 1
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    for literal in copyLiterals(in: line) where isDenied(literal, in: relative) {
                        hits.append("\(root)/\(relative):\(index + 1): \(literal)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scannedFiles, 250)
        XCTAssertEqual(hits, [], "user-facing copy names how the app is built:\n" + hits.joined(separator: "\n"))
    }

    func testScannerFlagsImplementationCopyAndIgnoresInterpolatedNames() {
        let flagged = copyLiterals(in: #"Label("Raw force samples are immutable; this edits metadata", systemImage: "lock")"#)
            .filter { isDenied($0, in: "Example.swift") }
        XCTAssertEqual(flagged, ["Raw force samples are immutable; this edits metadata"])

        let interpolated = copyLiterals(in: #"Text("\(quarantinedCount) not saved \(n == 1 ? "" : "s")")"#)
            .filter { isDenied($0, in: "Example.swift") }
        XCTAssertEqual(interpolated, [])

        XCTAssertEqual(copyLiterals(in: #"Self.log.error("server upsert failed")"#), [])
        XCTAssertEqual(copyLiterals(in: #"// "cached on the server""#), [])
    }

    private func isDenied(_ literal: String, in file: String) -> Bool {
        let lowered = literal.lowercased()
        guard deniedTerms.contains(where: lowered.contains) else { return false }
        return !technicalOnly.contains { file.hasSuffix($0.file) && literal.hasPrefix($0.prefix) }
    }

    private func copyLiterals(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || line.contains("\"\"\"") { return [] }
        if nonCopyLineMarkers.contains(where: line.contains) { return [] }
        var literals: [String] = []
        var current = ""
        var inLiteral = false
        var interpolationDepth = 0
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            if !inLiteral {
                if character == "\"" { inLiteral = true; current = "" }
                continue
            }
            if interpolationDepth > 0 {
                if character == "(" { interpolationDepth += 1 }
                if character == ")" { interpolationDepth -= 1 }
                if character == "\"" {
                    while let nested = characters.popFirst(), nested != "\"" {}
                }
                continue
            }
            if character == "\\" {
                if characters.first == "(" { characters.removeFirst(); interpolationDepth = 1 } else { _ = characters.popFirst() }
                current.append("\u{1}")
                continue
            }
            if character == "\"" {
                inLiteral = false
                let prose = current.replacingOccurrences(of: "\u{1}", with: "")
                let text = current.replacingOccurrences(of: "\u{1}", with: " ").trimmingCharacters(in: .whitespaces)
                if prose.contains(" ") || prose.first?.isUppercase == true { literals.append(text) }
                continue
            }
            current.append(character)
        }
        return literals
    }
}
