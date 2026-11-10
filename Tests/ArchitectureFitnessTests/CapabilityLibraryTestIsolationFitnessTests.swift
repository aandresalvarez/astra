import Foundation
import Testing

/// The rule this test defends: nothing the test binary runs may open the
/// person's capability library or its approval records.
///
/// The test binary resolves Application Support to the production folder
/// (`AstraDev` under `ASTRA_CHANNEL=dev`), and much of the plugin code opens
/// `CapabilityLibrary()` itself rather than taking one. Suites that install a
/// fixture for that code to find were installing it into the real library; one
/// of them had no cleanup and left 92 `add-commit-<uuid>.json` "Reports"
/// plugins in the production app by November 2026, beside over a thousand
/// "approved by user" records for fixtures in `CapabilityApprovals`.
///
/// `CapabilityLibrary.defaultDirectory()` and
/// `CapabilityApprovalStore.defaultDirectory()` now answer with a scratch
/// folder of the process in a test run. That holds only while three things
/// stay true,
/// and none of them fails at compile time: the default initializers go
/// through them, the test bundle declares itself before anything opens a
/// library, and nobody reaches around them by naming the Application Support
/// folders directly. `CapabilityLibraryTests` checks the result in the running
/// test binary; this pins the wiring.
@Suite("Capability Library Test Isolation Fitness")
struct CapabilityLibraryTestIsolationFitnessTests {
    /// The functions that name the Application Support folders.
    private static let realDirectoryCalls = ["capabilitiesDirectory(", "approvalsDirectory("]

    /// Files that may call them. Adding one needs a reason a default
    /// `CapabilityLibrary()` or `CapabilityApprovalStore()` cannot serve.
    private static let allowedAppFiles: Set<String> = [
        // Each owns its function and the default that wraps it.
        "Astra/Services/Capabilities/CapabilityLibrary.swift",
        "Astra/Services/Capabilities/CapabilityApprovalStore.swift",
        // Shows the folder's name; opens nothing.
        "Astra/Views/ConfigureView.swift"
    ]

    /// Tests that compare the per-channel paths as strings and open none.
    private static let allowedTestFiles: Set<String> = [
        "Tests/AppChannelStoragePathsTests.swift",
        "Tests/CapabilityApprovalTests.swift",
        "Tests/CapabilityLibraryTests.swift",
        "Tests/ArchitectureFitnessTests/CapabilityLibraryTestIsolationFitnessTests.swift"
    ]

    @Test("A default capability library and approval store go through the test-aware directories")
    func defaultsGoThroughTheTestAwareDirectories() throws {
        let root = repositoryRoot()
        let library = try text("Astra/Services/Capabilities/CapabilityLibrary.swift", root: root)
        #expect(library.contains("init(directory: URL = Self.defaultDirectory(),"))
        #expect(library.contains("testRunDirectory ?? capabilitiesDirectory()"))
        #expect(library.contains("static let testRunDirectory: URL? = AppLogger.isRunningTests"))
        let approvals = try text("Astra/Services/Capabilities/CapabilityApprovalStore.swift", root: root)
        #expect(approvals.contains("init(directory: URL = Self.defaultDirectory(),"))
        #expect(approvals.contains("CapabilityLibrary.testRunDirectory?.deletingLastPathComponent()"))
        #expect(approvals.contains("?? approvalsDirectory()"))
        // The answer is cached on first use, so the declaration has to come
        // from the load-time bootstrap rather than from a suite.
        let bootstrap = try text("Tests/RuntimeSeamTestBootstrap.swift", root: root)
        #expect(bootstrap.contains("AppLogger.markRunningUnderTests()"))
    }

    @Test("Only the library and the approval store name their Application Support folders")
    func onlyTheOwnersNameTheirApplicationSupportFolders() throws {
        let root = repositoryRoot()
        let callers = try files(under: ["Astra", "ASTRACore", "AppExecutable", "Tools", "Tests"], root: root)
            .filter { file in Self.realDirectoryCalls.contains { file.text.contains($0) } }
            .map(\.path)
        let unexpected = Set(callers).subtracting(Self.allowedAppFiles).subtracting(Self.allowedTestFiles).sorted()
        #expect(
            unexpected.isEmpty,
            """
            \(unexpected) call `capabilitiesDirectory(` or `approvalsDirectory(`, which are the \
            real Application Support folders even inside the test binary. Use `CapabilityLibrary()` \
            or `CapabilityApprovalStore()` (scratch folders in a test run) or pass the store in.
            """
        )
    }

    private func files(under directories: [String], root: URL) throws -> [(path: String, text: String)] {
        try directories.flatMap { directory -> [(path: String, text: String)] in
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { return [] }
            return try enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "swift",
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                return (url.path.replacingOccurrences(of: root.path + "/", with: ""),
                        try String(contentsOf: url, encoding: .utf8))
            }
        }
    }

    private func text(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
