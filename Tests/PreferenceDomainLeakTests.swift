import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// The rule these tests defend: pinning a preference for the duration of a test
/// must not cost a file in `~/Library/Preferences`.
///
/// The agent-policy tests used to mint `UserDefaults(suiteName:)` with a fresh
/// UUID per execution and clean up with `removePersistentDomain(forName:)`.
/// That call clears the domain's keys but never unlinks the plist, and
/// `cfprefsd` writes the emptied domain back to disk *after* the test process
/// exits — so no in-process teardown can win. The result was one permanent
/// 42-byte file per test execution, forever. `InMemoryDefaults` exists to make
/// that whole failure mode unreachable; these tests keep it that way.
@Suite("Preference domain leak")
struct PreferenceDomainLeakTests {
    private static let preferencesDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences", isDirectory: true)

    /// Counts preference plists left behind by the agent-policy suites. Nothing
    /// in the test target writes this prefix any more, so a stable count across
    /// simulated runs is the whole assertion — and it stays meaningful on a
    /// machine that still holds a backlog of previously leaked files.
    private static func agentPolicyDomainCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferencesDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("astra-agent-policy-") }.count
    }

    @Test("Simulated agent-policy runs do not accumulate preference domains")
    func simulatedRunsDoNotAccumulatePreferenceDomains() {
        let before = Self.agentPolicyDomainCount()

        // Far more iterations than a real `swift test` pass performs, so an
        // unbounded pattern shows up as an unmissable delta rather than noise.
        let simulatedRuns = 250
        for index in 0..<simulatedRuns {
            let layerNativeProviders = index.isMultiple(of: 2)
            let defaults = InMemoryDefaults()
            defaults.set(ExecutionSandboxEnforcement.bestEffort.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
            defaults.set(layerNativeProviders, forKey: AppStorageKeys.sandboxLayerNativeProviders)

            // Drive the real consumer, so this also proves the in-memory store
            // is a faithful stand-in and not just a quiet no-op.
            let resolution = ExecutionSandboxSettings.resolve(permissionPolicy: .restricted, defaults: defaults)
            #expect(resolution.storedEnforcement == .bestEffort)
            #expect(resolution.effectiveSettings.wrappedRuntimes.contains(.claudeCode))
            #expect(resolution.effectiveSettings.wrappedRuntimes.contains(.codexCLI) == layerNativeProviders)
        }

        let after = Self.agentPolicyDomainCount()
        #expect(
            after == before,
            """
            \(simulatedRuns) simulated runs added \(after - before) preference domains to \
            \(Self.preferencesDirectory.path). A test must not mint a per-run \
            `UserDefaults(suiteName:)`: `removePersistentDomain` does not unlink the plist and \
            `cfprefsd` rewrites it after the process exits. Use `InMemoryDefaults` instead.
            """
        )
    }

    @Test("InMemoryDefaults writes nothing to the persistent store")
    func inMemoryDefaultsWritesNothingToThePersistentStore() {
        let key = "astra.tests.preference-domain-leak.\(UUID().uuidString)"
        let defaults = InMemoryDefaults()
        defaults.set("pinned", forKey: key)

        #expect(defaults.string(forKey: key) == "pinned")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] == nil)
    }

    @Test("InMemoryDefaults backs the typed UserDefaults accessors")
    func inMemoryDefaultsBacksTheTypedAccessors() throws {
        let defaults = InMemoryDefaults(["seeded": "from-init"])
        #expect(defaults.string(forKey: "seeded") == "from-init")

        defaults.set("text", forKey: "string")
        defaults.set(true, forKey: "bool")
        defaults.set(7, forKey: "int")
        defaults.set(1.5, forKey: "double")
        defaults.set(["a", "b"], forKey: "array")

        #expect(defaults.string(forKey: "string") == "text")
        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.integer(forKey: "int") == 7)
        #expect(defaults.double(forKey: "double") == 1.5)
        #expect(defaults.stringArray(forKey: "array") == ["a", "b"])
        #expect(defaults.object(forKey: "bool") as? Bool == true)

        // Absent keys must read as absent rather than falling through to the
        // developer's real preferences.
        #expect(defaults.string(forKey: "never-set") == nil)
        #expect(defaults.object(forKey: "never-set") == nil)
        #expect(!defaults.bool(forKey: "never-set"))

        defaults.removeObject(forKey: "string")
        #expect(defaults.string(forKey: "string") == nil)

        defaults.set(nil, forKey: "bool")
        #expect(defaults.object(forKey: "bool") == nil)
    }

    @Test("Separate InMemoryDefaults instances stay isolated")
    func separateInstancesStayIsolated() {
        let first = InMemoryDefaults()
        let second = InMemoryDefaults()

        first.set(ExecutionSandboxEnforcement.strict.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        second.set(ExecutionSandboxEnforcement.off.rawValue, forKey: AppStorageKeys.sandboxEnforcement)

        #expect(first.string(forKey: AppStorageKeys.sandboxEnforcement) == ExecutionSandboxEnforcement.strict.rawValue)
        #expect(second.string(forKey: AppStorageKeys.sandboxEnforcement) == ExecutionSandboxEnforcement.off.rawValue)
    }
}
