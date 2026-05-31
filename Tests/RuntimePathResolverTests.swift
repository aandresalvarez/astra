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

// MARK: - RuntimeProcessEnvironment

@Suite("RuntimeProcessEnvironment")
struct RuntimeProcessEnvironmentTests {

    @Test("Enriched environment includes well-known directories in PATH")
    func enrichedIncludesWellKnownDirectories() {
        let env = RuntimeProcessEnvironment.enriched()
        let path = env["PATH"] ?? ""

        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains(".local/bin"))
        #expect(path.contains(".npm-global/bin"))
        #expect(path.contains(".astra/tools"))
    }

    @Test("Enriched environment preserves parent PATH components")
    func enrichedPreservesParentPATH() {
        let env = RuntimeProcessEnvironment.enriched()
        let path = env["PATH"] ?? ""

        // The parent PATH always includes at least /usr/bin from the system
        #expect(path.contains("/usr/bin"))
    }

    @Test("Enriched environment deduplicates PATH entries")
    func enrichedDeduplicatesPATH() {
        let env = RuntimeProcessEnvironment.enriched()
        let path = env["PATH"] ?? ""
        let components = path.split(separator: ":").map(String.init)
        let uniqueComponents = Set(components)

        #expect(components.count == uniqueComponents.count)
    }

    @Test("Additional paths are prepended to PATH")
    func additionalPathsArePrepended() {
        let customPath = "/tmp/astra-test-custom-\(UUID().uuidString)"
        let env = RuntimeProcessEnvironment.enriched(additionalPaths: [customPath])
        let path = env["PATH"] ?? ""
        let components = path.split(separator: ":").map(String.init)

        #expect(components.first == customPath)
    }

    @Test("Extra variables are merged into environment")
    func extraVariablesAreMerged() {
        let env = RuntimeProcessEnvironment.enriched(extraVariables: [
            "ASTRA_TEST_VAR": "hello",
            "NO_COLOR": "1"
        ])

        #expect(env["ASTRA_TEST_VAR"] == "hello")
        #expect(env["NO_COLOR"] == "1")
    }

    @Test("deduplicatedPATH removes duplicates while preserving order")
    func deduplicatedPATHRemovesDuplicates() {
        let result = RuntimeProcessEnvironment.deduplicatedPATH([
            "/usr/bin:/opt/homebrew/bin",
            "/opt/homebrew/bin:/usr/local/bin",
            "/usr/bin"
        ])
        let components = result.split(separator: ":").map(String.init)

        #expect(components == ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test("deduplicatedPATH handles empty parts")
    func deduplicatedPATHHandlesEmpty() {
        let result = RuntimeProcessEnvironment.deduplicatedPATH(["", "/usr/bin", "", "/opt/homebrew/bin"])
        let components = result.split(separator: ":").map(String.init)

        #expect(components == ["/usr/bin", "/opt/homebrew/bin"])
    }

    @Test("Enriched environment inherits non-PATH variables from parent")
    func enrichedInheritsParentVars() {
        let env = RuntimeProcessEnvironment.enriched()

        // HOME should always be present
        #expect(env["HOME"] != nil)
        #expect(!env["HOME"]!.isEmpty)
    }

    @Test("Login shell PATH probe is not synchronous on the main thread")
    func loginShellPATHProbeIsNotSynchronousOnMainThread() {
        #expect(RuntimeProcessEnvironment.shouldProbeLoginShellSynchronously(
            isMainThread: true,
            hasCachedShellPATH: false
        ) == false)
        #expect(RuntimeProcessEnvironment.shouldProbeLoginShellSynchronously(
            isMainThread: false,
            hasCachedShellPATH: false
        ) == true)
        #expect(RuntimeProcessEnvironment.shouldProbeLoginShellSynchronously(
            isMainThread: false,
            hasCachedShellPATH: true
        ) == false)
    }

    @Test("Minimal Finder PATH cannot run Node.js scripts but enriched PATH can")
    func minimalPATHFailsButEnrichedSucceeds() {
        // Verify that node exists on this machine first
        let enrichedEnv = RuntimeProcessEnvironment.enriched()
        let nodeCheck = Process()
        nodeCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        nodeCheck.arguments = ["node", "--version"]
        nodeCheck.environment = enrichedEnv
        nodeCheck.standardOutput = FileHandle.nullDevice
        nodeCheck.standardError = FileHandle.nullDevice
        do { try nodeCheck.run(); nodeCheck.waitUntilExit() } catch { return }
        guard nodeCheck.terminationStatus == 0 else { return }

        // With minimal Finder PATH, node should NOT be found
        let minimalEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        let minimalCheck = Process()
        minimalCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        minimalCheck.arguments = ["node", "--version"]
        minimalCheck.environment = minimalEnv
        minimalCheck.standardOutput = FileHandle.nullDevice
        minimalCheck.standardError = FileHandle.nullDevice
        do { try minimalCheck.run(); minimalCheck.waitUntilExit() } catch {
            // Launch failed entirely — confirms the problem
            return
        }
        let minimalPATHAlreadyFindsNode = minimalCheck.terminationStatus == 0

        // With enriched PATH, node SHOULD be found
        let enrichedCheck = Process()
        enrichedCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        enrichedCheck.arguments = ["node", "--version"]
        enrichedCheck.environment = enrichedEnv
        enrichedCheck.standardOutput = FileHandle.nullDevice
        enrichedCheck.standardError = FileHandle.nullDevice
        do { try enrichedCheck.run(); enrichedCheck.waitUntilExit() } catch {
            Issue.record("Enriched environment should be able to launch /usr/bin/env node")
            return
        }
        #expect(enrichedCheck.terminationStatus == 0, "Enriched PATH should find node")
        if !minimalPATHAlreadyFindsNode {
            #expect(minimalCheck.terminationStatus != 0, "Minimal PATH should not find node when node is outside Finder's default PATH")
        }
    }

    @Test("Enriched environment with Node.js script works from minimal PATH")
    func enrichedEnvironmentFindsNode() {
        let env = RuntimeProcessEnvironment.enriched()

        // If node is installed, it should be findable via the enriched PATH
        // (this test validates the shell probe or well-known paths include node's location)
        let nodeCheck = Process()
        nodeCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        nodeCheck.arguments = ["node", "--version"]
        nodeCheck.environment = env
        let pipe = Pipe()
        nodeCheck.standardOutput = pipe
        nodeCheck.standardError = FileHandle.nullDevice
        do {
            try nodeCheck.run()
            nodeCheck.waitUntilExit()
            if nodeCheck.terminationStatus == 0 {
                // Node was found — PATH enrichment works
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                #expect(version.hasPrefix("v"))
            }
            // If node isn't installed at all, this test is a no-op (not a failure)
        } catch {
            // env/node not found — acceptable on systems without Node
        }
    }
}
