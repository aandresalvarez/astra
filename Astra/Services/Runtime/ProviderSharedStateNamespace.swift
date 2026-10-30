import Darwin
import Foundation

/// Test isolation is declared at bundle load, before any gate can be used.
/// The UUID travels through the wrapper's environment to helper processes;
/// neither a process name nor a provider/profile path grants this scope.
enum ProviderSharedStateNamespace {
    static let environmentKey = "ASTRA_TEST_PROVIDER_NAMESPACE_ID"
    // Written only by the single-threaded test bundle constructor.
    nonisolated(unsafe) private static var testBundleLoaded = false

    static func markRunningUnderTests() {
        testBundleLoaded = true
        if getenv(environmentKey) == nil {
            setenv(environmentKey, UUID().uuidString, 0)
        }
    }

    static var sharedRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASTRA Runtime Coordination/provider-state", isDirectory: true)
    }

    static func isolatedRoot(_ id: UUID) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("astra-provider-tests-\(id.uuidString)", isDirectory: true)
    }

    static func resolve(override: URL? = nil) throws -> URL {
        try resolve(override: override, environment: ProcessInfo.processInfo.environment,
                    testBundleLoaded: testBundleLoaded)
    }

    static func validateResource(_ key: AgentRuntimeSharedStateKey) throws {
        guard testBundleLoaded || ProcessInfo.processInfo.environment[environmentKey] != nil,
              let path = key.filePath else { return }
        guard isTemporary(URL(fileURLWithPath: path)) else {
            throw RuntimeExecutionOwnerStore.Failure.unsafePath
        }
    }

    static func resolve(override: URL?, environment: [String: String], testBundleLoaded: Bool) throws -> URL {
        let value = environment[environmentKey]
        guard testBundleLoaded || value != nil else { return override ?? sharedRoot }
        // Malformed or removed inheritance must fail closed, never fall back
        // to the user's shared namespace after the bundle declares a test run.
        guard let value, let id = UUID(uuidString: value) else {
            throw RuntimeExecutionOwnerStore.Failure.unsafePath
        }
        guard let override else { return isolatedRoot(id) }
        guard let path = try? ProviderSharedStateIdentity.canonicalPath(override.path),
              let shared = try? ProviderSharedStateIdentity.canonicalPath(sharedRoot.path),
              isTemporary(override), path != shared, !path.hasPrefix(shared + "/") else {
            throw RuntimeExecutionOwnerStore.Failure.unsafePath
        }
        return override
    }

    private static func isTemporary(_ url: URL) -> Bool {
        guard let path = try? ProviderSharedStateIdentity.canonicalPath(url.path) else { return false }
        let roots = [URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/private/tmp")]
        // Use the same filesystem/Unicode/case rules as the resource key.
        // Foundation can spell /private/tmp differently for missing children.
        return roots.contains {
            guard let root = try? ProviderSharedStateIdentity.canonicalPath($0.path) else { return false }
            return path.hasPrefix(root + "/")
        }
    }
}
