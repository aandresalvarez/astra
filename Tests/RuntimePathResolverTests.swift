import Foundation
import Testing
@testable import ASTRA

@Suite("RuntimePathResolver")
struct RuntimePathResolverTests {
    @Test("Generic resolver returns executable candidate before falling back")
    func genericResolverFindsExecutableCandidate() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RuntimePathResolverTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("astra-test-tool")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = RuntimePathResolver.detectExecutablePath(
            named: "astra-test-tool",
            candidates: [executable.path],
            fileManager: fileManager
        )

        #expect(resolved == executable.path)
    }

    @Test("Generic resolver covers system tools")
    func genericResolverCoversSystemTools() {
        let resolved = RuntimePathResolver.detectExecutablePath(named: "security")

        #expect(resolved == "/usr/bin/security")
    }

    @Test("Generic resolver returns fallback for unknown tools")
    func genericResolverReturnsFallbackForUnknownTools() {
        let missing = "astra-missing-\(UUID().uuidString)"
        let resolved = RuntimePathResolver.detectExecutablePath(
            named: missing,
            fallback: "/tmp/fallback-tool"
        )

        #expect(resolved == "/tmp/fallback-tool")
    }
}
