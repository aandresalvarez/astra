import Darwin
import Foundation

/// Test helpers inherit the run UUID. Every physical fixture profile selects
/// its own coordination directory, including when a caller supplies an override.
enum ProviderSharedStateNamespace {
    static let environmentKey = "ASTRA_TEST_PROVIDER_NAMESPACE_ID"
    private static let prefix = "astra-provider-tests-"
    nonisolated(unsafe) private static var testBundleLoaded = false

    static func markRunningUnderTests() {
        testBundleLoaded = true
        if getenv(environmentKey) == nil { setenv(environmentKey, UUID().uuidString, 0) }
    }

    static var sharedRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASTRA Runtime Coordination/provider-state", isDirectory: true)
    }

    static func isolatedRoot(_ id: UUID) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(prefix + id.uuidString, isDirectory: true)
    }

    static func coordinationRoot(in run: URL, fixtureID: UUID) -> URL {
        run.appendingPathComponent("coordination").appendingPathComponent(fixtureID.uuidString)
    }

    static func resolve(override: URL? = nil, key: AgentRuntimeSharedStateKey? = nil) throws -> URL {
        try resolve(override: override, environment: ProcessInfo.processInfo.environment,
                    testBundleLoaded: testBundleLoaded, key: key)
    }

    static func resolve(override: URL?, environment: [String: String], testBundleLoaded: Bool,
                        key: AgentRuntimeSharedStateKey? = nil) throws -> URL {
        let value = environment[environmentKey]
        let resource = try key?.filePath.map { try ProviderSharedStateIdentity.canonicalPath($0) }
        let fixture = resource.flatMap(testLocation)
        guard testBundleLoaded || value != nil else {
            guard fixture == nil else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
            return try physicalParent(of: override ?? sharedRoot)
        }
        guard let value, let runID = UUID(uuidString: value) else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        let run = isolatedRoot(runID)
        var expected: URL?
        if resource != nil {
            guard resource == key?.filePath, let fixture, fixture.run == runID, fixture.standardSpelling,
                  fixture.suffix.count >= 3, fixture.suffix[0] == "fixtures",
                  let fixtureID = UUID(uuidString: fixture.suffix[1]) else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
            expected = coordinationRoot(in: run, fixtureID: fixtureID)
        }
        if let override {
            guard let physical = try? physicalParent(of: override),
                  let path = try? ProviderSharedStateIdentity.canonicalPath(physical.path),
                  let location = testLocation(path), location.run == runID, location.standardSpelling,
                  try expected.map({ try ProviderSharedStateIdentity.canonicalPath($0.path) == path }) ?? true
            else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
            return expected ?? physical
        }
        return expected ?? run
    }

    /// Resolve parent aliases before opening the directory. Its final component
    /// must itself pass the no-follow, ownership and permissions checks.
    private static func physicalParent(of url: URL) throws -> URL {
        // A directory is opened by its actual spelling. Provider key folding
        // and the HFS+ Unicode policy apply only to provider settings.
        var parent = url.deletingLastPathComponent()
        var missing: [String] = []
        while true {
            if let physical = realpath(parent.path, nil) {
                defer { free(physical) }
                var result = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                for component in missing.reversed() { result.appendPathComponent(component, isDirectory: true) }
                return result.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            }
            var info = stat()
            guard errno == ENOENT, lstat(parent.path, &info) != 0, errno == ENOENT,
                  !["", "/", ".", ".."].contains(parent.lastPathComponent) else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
    }

    private struct Location {
        let run: UUID
        let standardSpelling: Bool
        let suffix: [String]
    }

    /// APFS exposes /private/tmp through its Data volume as well. Detect the
    /// directory by device/inode and refuse alternate spellings for test locks.
    private static func testLocation(_ path: String) -> Location? {
        guard path.contains("/" + prefix) else { return nil }
        let parts = path.split(separator: "/")
        for i in parts.indices where parts[i].hasPrefix(prefix) {
            guard let run = UUID(uuidString: String(parts[i].dropFirst(prefix.count))) else { continue }
            let parent = "/" + parts[..<i].joined(separator: "/")
            var actual = stat(), temporary = stat()
            guard stat(parent, &actual) == 0, stat("/private/tmp", &temporary) == 0,
                  actual.st_dev == temporary.st_dev, actual.st_ino == temporary.st_ino else { continue }
            return Location(run: run, standardSpelling: parent == "/private/tmp", suffix: parts[(i+1)...].map(String.init))
        }
        return nil
    }
}
