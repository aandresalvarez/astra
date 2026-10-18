import Testing
import Foundation
import ASTRACore
@testable import ASTRA

@Suite("Runtime home access", .enabled(if: getuid() != 0))
struct RuntimeHomeAccessTests {
    @Test("Every registered runtime declares its own startup layout")
    func allAdaptersDeclarePolicies() {
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let policy = AgentRuntimeAdapterRegistry.adapter(for: runtime).homeAccessPolicy
            #expect(!policy.roots.isEmpty, "Missing home policy for \(runtime.rawValue)")
            #expect(RuntimeReadinessService.uncachedCheckIDs.contains(RuntimeHomeAccessService.checkID(for: runtime)))
        }
    }

    @Test("Every runtime accepts readable configuration, including read-only files", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func healthyHomes(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        #expect(await RuntimeHomeAccessService.check(fixture.request)?.state != .blocked)
    }

    @Test("An unreadable startup config is refused by the actual launch guard", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func unreadableConfigBlocks(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        let file = try #require(fixture.files.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: runtime, executablePath: "/unused/provider", arguments: [], currentDirectory: fixture.home,
            environment: ["HOME": fixture.home], browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false
        )
        let message = await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: nil)
        #expect(message?.contains((file as NSString).lastPathComponent) == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file)
        #expect(await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: nil) == nil)
    }

    @Test("Every runtime rejects a directory where a startup config file belongs", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func wrongConfigKind(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        let file = try #require(fixture.files.first)
        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        #expect(await RuntimeHomeAccessService.check(fixture.request)?.state == .blocked)
    }

    @Test("Unknown backups and historical sessions do not block startup", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func historyIsNotTraversed(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        let root = try #require(fixture.request.policy.roots.first).path(
            environment: [:], userHome: fixture.home, workingDirectory: fixture.home
        )
        let backup = (root as NSString).appendingPathComponent("config.json.bak")
        FileManager.default.createFile(atPath: backup, contents: Data(), attributes: [.posixPermissions: 0])
        let history = (root as NSString).appendingPathComponent("sessions/old/private")
        try FileManager.default.createDirectory(atPath: history, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: history + "/transcript", contents: Data(), attributes: [.posixPermissions: 0])
        let result = await RuntimeHomeAccessService.check(fixture.request)
        #expect(result?.state != .blocked)
    }

    @Test("The provider home override replaces an unusable default", arguments: [AgentRuntimeID.claudeCode, .codexCLI, .cursorCLI])
    func homeOverrides(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        var request = fixture.request
        let root = try #require(request.policy.roots.first)
        let variable = try #require(root.variable)
        let file = try #require(fixture.files.first)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        let replacement = fixture.home + "/custom profile"
        try FileManager.default.createDirectory(atPath: replacement, withIntermediateDirectories: true)
        request.environment[variable] = replacement
        #expect(await RuntimeHomeAccessService.check(request) == nil)
    }

    @Test("A missing home must be creatable under the effective parent", arguments: [AgentRuntimeID.copilotCLI, .codexCLI])
    func missingHomeUnderReadOnlyParent(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        let parent = fixture.home + "/read-only-parent"
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        var request = fixture.request
        let variable = try #require(request.policy.roots.first?.variable)
        request.environment[variable] = parent + "/missing-home"
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
        let result = try runShell(RuntimeHomeAccessContainerCommand.script(policy: request.policy), home: fixture.home,
                                  environment: [variable: parent + "/missing-home"])
        #expect(result.exitCode == 78)
        #expect(result.stdout.isEmpty)
    }

    @Test("Claude's custom profile owns its global configuration too")
    func customClaudeGlobalConfig() async throws {
        let fixture = try Fixture(.claudeCode)
        defer { fixture.remove() }
        var request = fixture.request
        let custom = fixture.home + "/custom"
        try FileManager.default.createDirectory(atPath: custom, withIntermediateDirectories: true)
        let inactive = fixture.home + "/.claude.json"
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inactive)
        request.environment["CLAUDE_CONFIG_DIR"] = custom
        #expect(await RuntimeHomeAccessService.check(request) == nil)
        FileManager.default.createFile(atPath: custom + "/.claude.json", contents: Data(), attributes: [.posixPermissions: 0])
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
    }

    @Test("Relative Claude configuration is checked from the provider working directory")
    func relativeClaudeGlobalConfig() async throws {
        let fixture = try Fixture(.claudeCode)
        defer { fixture.remove() }
        let custom = fixture.home + "/relative profile"
        try FileManager.default.createDirectory(atPath: custom, withIntermediateDirectories: true)
        let file = custom + "/.claude.json"
        FileManager.default.createFile(atPath: file, contents: Data(), attributes: [.posixPermissions: 0])
        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: .claudeCode, executablePath: "/unused/claude", arguments: [], currentDirectory: fixture.home,
            environment: ["HOME": fixture.home, "CLAUDE_CONFIG_DIR": "relative profile"],
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true
        )
        let block = await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: nil)
        #expect(block?.contains(".claude.json") == true)
        let script = RuntimeHomeAccessContainerCommand.script(policy: fixture.request.policy)
        let refused = try runShell(script, home: fixture.home, environment: ["CLAUDE_CONFIG_DIR": "relative profile"])
        #expect(refused.exitCode == 78)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file)
        #expect(await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: nil) == nil)
        #expect(try runShell(script, home: fixture.home, environment: ["CLAUDE_CONFIG_DIR": "relative profile"]).exitCode == 0)
    }

    @Test("OpenCode checks its custom config and honors XDG homes")
    func openCodeCustomConfig() async throws {
        let fixture = try Fixture(.openCodeCLI)
        defer { fixture.remove() }
        var request = fixture.request
        let config = fixture.home + "/custom config.json"
        FileManager.default.createFile(atPath: config, contents: Data(), attributes: [.posixPermissions: 0])
        request.environment["OPENCODE_CONFIG"] = config
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config)
        request.environment["XDG_DATA_HOME"] = fixture.home + "/other-data"
        #expect(await RuntimeHomeAccessService.check(request) == nil)
        let result = try runShell(RuntimeHomeAccessContainerCommand.script(policy: request.policy), home: fixture.home,
                                  environment: request.environment)
        #expect(result.exitCode == 0)
    }

    @Test("Cursor's Linux container respects XDG configuration")
    func cursorContainerXDG() throws {
        let fixture = try Fixture(.cursorCLI)
        defer { fixture.remove() }
        let xdg = fixture.home + "/xdg/cursor"
        try FileManager.default.createDirectory(atPath: xdg, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: xdg + "/cli-config.json", contents: Data(), attributes: [.posixPermissions: 0])
        let result = try runShell(RuntimeHomeAccessContainerCommand.script(policy: fixture.request.policy), home: fixture.home,
                                  environment: ["XDG_CONFIG_HOME": fixture.home + "/xdg"])
        #expect(result.exitCode == 78)
        #expect(result.stderr.contains(xdg))
    }

    @Test("Codex ignores an unreadable user config when ASTRA disables user configuration")
    func codexIgnoresUnusedUserConfig() async throws {
        let fixture = try Fixture(.codexCLI)
        defer { fixture.remove() }
        let ignored = fixture.home + "/.codex/config.toml"
        FileManager.default.createFile(atPath: ignored, contents: Data(), attributes: [.posixPermissions: 0])
        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: .codexCLI, executablePath: "/unused/codex", arguments: ["exec", "--ignore-user-config"],
            currentDirectory: fixture.home, environment: ["HOME": fixture.home],
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true
        )
        #expect(await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: nil) == nil)
        let container = try runShell(RuntimeHomeAccessContainerCommand.script(policy: fixture.request.policy), home: fixture.home)
        #expect(container.exitCode == 0)
    }

    @Test("A sandbox denial blocks mutable state but allows hardened read-only config")
    func respectsAppliedSandbox() async throws {
        let fixture = try Fixture(.codexCLI)
        defer { fixture.remove() }
        var request = fixture.request
        let root = fixture.home + "/.codex"
        request.sandboxReceipt = .init(writableRoots: [root], writeDeniedRoots: [root + "/config.toml"])
        #expect(await RuntimeHomeAccessService.check(request) == nil)
        request.sandboxReceipt = .init(writableRoots: [root], writeDeniedRoots: [root + "/sessions"])
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
    }

    @MainActor
    @Test("Filesystem probing runs off the UI thread", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func probeDoesNotBlockMainActor(runtime: AgentRuntimeID) async throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        let result = await RuntimeHomeAccessService.check(fixture.request, inspector: { request in
            // Check the execution context at the filesystem boundary itself.
            // A deadline/heartbeat would test unrelated suite load as well.
            #expect(!Thread.isMainThread)
            return RuntimeHomeAccessService.inspect(request)
        })
        #expect(result?.state != .blocked)
    }

    @Test("Container policy checks the container home before invoking every provider", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func containerPolicy(runtime: AgentRuntimeID) throws {
        let fixture = try Fixture(runtime)
        defer { fixture.remove() }
        let policy = fixture.request.policy
        let script = RuntimeHomeAccessContainerCommand.script(policy: policy)
        let healthy = try runShell(script, home: fixture.home)
        #expect(healthy.exitCode == 0)
        #expect(healthy.stdout == "provider-reached\n")
        let file = try #require(fixture.files.first)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        let refused = try runShell(script, home: fixture.home)
        #expect(refused.exitCode == 78)
        #expect(refused.stdout.isEmpty)
        #expect(refused.stderr.contains(RuntimeHomeAccessContainerCommand.failureMarker))
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: runtime, model: "test", exitCode: 78, rawError: refused.stderr, providerVersion: nil, stream: nil
        )
        #expect(diagnostic.category == .providerHomeAccessDenied)
    }

    @Test("An unused host home cannot block a provider running inside a container")
    func containerSkipsHostProbe() async throws {
        let fixture = try Fixture(.codexCLI)
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: #require(fixture.files.first))
        var request = fixture.request
        request.insideContainer = true
        #expect(await RuntimeHomeAccessService.check(request) == nil)
    }

    private struct Fixture {
        let home: String
        let request: RuntimeHomeAccessRequest
        let files: [String]

        init(_ runtime: AgentRuntimeID) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("astra-home-access-\(UUID().uuidString)").path
            let policy = AgentRuntimeAdapterRegistry.adapter(for: runtime).homeAccessPolicy
            request = .init(runtime: runtime, policy: policy, environment: ["HOME": home], workingDirectory: home, userHome: home)
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            var paths: [String] = []
            for root in policy.roots {
                let path = root.path(environment: [:], userHome: home, workingDirectory: home)
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                for name in root.files {
                    let file = (path as NSString).appendingPathComponent(name)
                    try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: file, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o400])
                    paths.append(file)
                }
                for name in root.directories {
                    try FileManager.default.createDirectory(atPath: (path as NSString).appendingPathComponent(name), withIntermediateDirectories: true)
                }
            }
            for name in policy.homeFiles {
                let file = (home as NSString).appendingPathComponent(name)
                FileManager.default.createFile(atPath: file, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o400])
                paths.append(file)
            }
            files = paths
        }

        func remove() { try? FileManager.default.removeItem(atPath: home) }
    }

    private func runShell(_ script: String, home: String, environment: [String: String] = [:]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        process.arguments = ["-c", script, "astra-home-preflight", "/usr/bin/printf", "provider-reached\\n"]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"].merging(environment) { _, explicit in explicit }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }
}
