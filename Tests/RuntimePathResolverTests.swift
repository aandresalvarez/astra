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

    @Test("Generic resolver covers per-user Google Cloud SDK tools")
    func genericResolverCoversUserGoogleCloudSDKTools() {
        let bqPath = "\(NSHomeDirectory())/google-cloud-sdk/bin/bq"
        let fileManager = RuntimePathResolverExecutableFileManager(executablePaths: Set([bqPath]))

        let resolved = RuntimePathResolver.detectExecutablePath(
            named: "bq",
            fileManager: fileManager
        )

        #expect(resolved == bqPath)
    }

    @Test("Generic resolver accepts explicit executable paths")
    func genericResolverAcceptsExplicitExecutablePaths() {
        let executablePath = "/tmp/astra-explicit-tool-\(UUID().uuidString)"
        let fileManager = RuntimePathResolverExecutableFileManager(executablePaths: Set([executablePath]))

        let resolved = RuntimePathResolver.detectExecutablePath(
            named: executablePath,
            fileManager: fileManager
        )

        #expect(resolved == executablePath)
    }

    @Test("Generic resolver expands tilde in explicit executable paths")
    func genericResolverExpandsTildeInExplicitExecutablePaths() {
        let expandedPath = "\(NSHomeDirectory())/google-cloud-sdk/bin/bq"
        let fileManager = RuntimePathResolverExecutableFileManager(executablePaths: Set([expandedPath]))

        let resolved = RuntimePathResolver.detectExecutablePath(
            named: "~/google-cloud-sdk/bin/bq",
            fileManager: fileManager
        )

        #expect(resolved == expandedPath)
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

    @Test("Docker resolver finds the CLI inside Docker Desktop without relying on PATH")
    func dockerResolverFindsApplicationBundleCLI() {
        let bundlePath = "/Applications/Docker.app/Contents/Resources/bin/docker"
        let fileManager = RuntimePathResolverExecutableFileManager(executablePaths: Set([bundlePath]))

        let resolved = RuntimePathResolver.detectDockerPath(fileManager: fileManager)

        #expect(resolved == bundlePath)
    }

    @Test("Docker resolver searches the enriched environment PATH")
    func dockerResolverSearchesProvidedEnvironmentPATH() {
        let customPath = "/nix/profile/bin/docker"
        let fileManager = RuntimePathResolverExecutableFileManager(executablePaths: Set([customPath]))

        let resolved = RuntimePathResolver.detectDockerPath(
            environment: ["PATH": "/nix/profile/bin:/usr/bin:/bin"],
            fileManager: fileManager
        )

        #expect(resolved == customPath)
    }

    @Test("Docker runtime prepends the CLI directory for companion tools")
    func dockerRuntimePrependsExecutableDirectory() throws {
        let runtime = DockerRuntimeResolver.resolution(
            executablePath: "/Applications/Docker.app/Contents/Resources/bin/docker",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        #expect(runtime.executablePath == "/Applications/Docker.app/Contents/Resources/bin/docker")
        #expect(runtime.environment["PATH"] == "/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin")
    }

    @Test("Docker runtime also prepends the symlink's resolved target directory")
    func dockerRuntimePrependsResolvedSymlinkTargetDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-docker-path-symlink-\(UUID().uuidString)")
        let targetDirectory = root.appendingPathComponent("Docker.app/Contents/Resources/bin", isDirectory: true)
        let linkDirectory = root.appendingPathComponent("usr-local-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        let targetExecutable = targetDirectory.appendingPathComponent("docker")
        try Data().write(to: targetExecutable)
        let linkExecutable = linkDirectory.appendingPathComponent("docker")
        try FileManager.default.createSymbolicLink(at: linkExecutable, withDestinationURL: targetExecutable)
        defer { try? FileManager.default.removeItem(at: root) }

        // Sanity check the fixture actually exercises a symlink whose
        // resolved target differs from the link's own directory.
        try #require((linkExecutable.path as NSString).resolvingSymlinksInPath != linkExecutable.path)

        let runtime = DockerRuntimeResolver.resolution(
            executablePath: linkExecutable.path,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        #expect(runtime.environment["PATH"] == "\(linkDirectory.path):\(targetDirectory.path):/usr/bin:/bin")
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
        #expect(path.contains("/google-cloud-sdk/bin"))
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

private final class RuntimePathResolverExecutableFileManager: FileManager {
    private let executablePaths: Set<String>

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}
