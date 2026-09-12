import Foundation
import Testing

/// The rule this test defends: a test must not mint its own `UserDefaults`
/// suite.
///
/// `UserDefaults(suiteName: "…-\(UUID())")` costs a permanent file in
/// `~/Library/Preferences`. The usual `defer { removePersistentDomain(...) }`
/// does not reclaim it — that call clears the domain's keys but leaves the
/// plist, and `cfprefsd` rewrites the emptied domain to disk after the test
/// process exits, so unlinking it from inside the test does not help either.
/// Every `swift test` run therefore leaves another batch of 42-byte plists
/// behind for good, and a `~/Library/Preferences` holding tens of thousands of
/// them slows down everything that enumerates preference domains (`defaults
/// domains`, System Settings, login).
///
/// `Tests/InMemoryDefaultsTestSupport.swift` provides `InMemoryDefaults`, a
/// drop-in `UserDefaults` that never registers a domain. This is a ratchet
/// rather than a ban: the sites below predate the helper, and the count may
/// only go down.
@Suite("Preference Domain Fitness")
struct PreferenceDomainFitnessTests {
    /// Files that name the banned pattern in prose or in a diagnostic message
    /// rather than calling it.
    private static let exemptFileNames: Set<String> = [
        "InMemoryDefaultsTestSupport.swift",
        "PreferenceDomainLeakTests.swift",
        "PreferenceDomainFitnessTests.swift"
    ]

    /// Lower this as suites migrate to `InMemoryDefaults`. Never raise it.
    private static let allowedSuiteConstructionSites = 51

    @Test("Test suites do not mint per-run UserDefaults domains")
    func testSuitesDoNotMintPerRunUserDefaultsDomains() throws {
        let root = try repositoryRoot()
        var siteCountsByFile: [String: Int] = [:]

        for file in try swiftFiles(under: root.appendingPathComponent("Tests")) {
            guard !Self.exemptFileNames.contains(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.components(separatedBy: "UserDefaults(suiteName").count - 1
            guard count > 0 else { continue }
            siteCountsByFile[file.lastPathComponent] = count
        }

        let total = siteCountsByFile.values.reduce(0, +)

        #expect(
            total <= Self.allowedSuiteConstructionSites,
            """
            \(total) `UserDefaults(suiteName:)` sites in Tests/, up from the allowed \
            \(Self.allowedSuiteConstructionSites). Each one leaks a plist into \
            ~/Library/Preferences on every test execution that reaches it — \
            `removePersistentDomain` does not unlink the file and cfprefsd rewrites it after \
            the process exits. Use `InMemoryDefaults` (Tests/InMemoryDefaultsTestSupport.swift) \
            instead. Remaining sites: \
            \(siteCountsByFile.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            """
        )

        #expect(
            total >= Self.allowedSuiteConstructionSites,
            """
            Only \(total) `UserDefaults(suiteName:)` sites remain in Tests/. Lower \
            `allowedSuiteConstructionSites` to \(total) so the ratchet keeps holding.
            """
        )
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw CocoaError(.fileNoSuchFile)
            }
            candidate = parent
        }
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
