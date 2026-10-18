import Testing
import Foundation
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime home access edge cases", .enabled(if: getuid() != 0))
struct RuntimeHomeAccessEdgeCaseTests {
    @Test("Every provider stops at a dangling ancestor instead of accepting a writable grandparent",
          arguments: AgentRuntimeAdapterRegistry.runtimeIDs, ["dangling", "loop"])
    func brokenAncestor(runtime: AgentRuntimeID, mode: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let link = home + "/linked"
        let target = home + "/target"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: mode == "loop" ? link : target)
        let providerHome = link + "/nested"
        let request = RuntimeHomeAccessRequest(runtime: runtime, policy: AgentRuntimeAdapterRegistry.homeAccessPolicy(for: runtime),
                                               environment: ["HOME": providerHome], workingDirectory: home, userHome: providerHome)
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
        #expect(try shell(runtime: runtime, home: home, environment: ["HOME": providerHome]).exitCode == 78)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(await RuntimeHomeAccessService.check(request)?.state != .blocked)
        #expect(try shell(runtime: runtime, home: home, environment: ["HOME": providerHome]).exitCode == 0)
    }

    @MainActor
    @Test("Shell capability is checked against the planned mounted filesystem")
    func probeIncludesEffectiveMounts() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var original = try containerPlan(home: home)
        original.executionEnvironment.mounts.append(.init(hostPath: home + "/not-a-shell", containerPath: "/bin/sh", access: .readWrite, role: .additionalPath))
        let record = ProbeRecord()
        let prepared = await RuntimeHomeAccessContainerPreflight.prepare(original, resumeSessionID: nil, runner: MountedShellRunner(record: record))
        let call = try #require(await record.calls.first)
        #expect(call.contains(where: { $0.contains("target=/bin/sh") && $0.contains("readonly") }))
        #expect(prepared.arguments == original.arguments)
        #expect(prepared.commandPlannedFields["provider_home_access_check"] == "not_checked_shell_probe_failed")
    }

    struct MountedShellRunner: BinaryRunner {
        let record: ProbeRecord
        func run(path: String, args: [String], timeout: TimeInterval, environment: [String: String]?) async -> RunResult {
            await record.append(args)
            return .exited(code: args.contains(where: { $0.contains("target=/bin/sh") }) ? 126 : 0, stdout: "", stderr: "")
        }
    }

    @MainActor
    @Test("Real Docker preserves a valid provider command when mounts hide the shell or its target",
          .enabled(if: ProcessInfo.processInfo.environment["ASTRA_LIVE_HOME_DOCKER"] == "1"),
          arguments: ["/bin", "/bin/sh", "/qa-shell", "/qa-shell/sh"])
    func realDockerMountedShell(target: String) async throws {
        let image = try #require(ProcessInfo.processInfo.environment["ASTRA_HOME_MOUNTED_SHELL_IMAGE"])
        let docker = try #require(DockerRuntimeResolver.resolve(environment: RuntimeProcessEnvironment.enriched()))
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let source = home + "/shadow,source"
        if target.hasSuffix("/sh") { FileManager.default.createFile(atPath: source, contents: Data(), attributes: [.posixPermissions: 0o400]) }
        else { try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false) }
        let mount = ExecutionEnvironmentMount(hostPath: source, containerPath: target, access: .readOnly, role: .additionalPath)
        let args = ["run", "--rm", "--pull", "never", "--network", "none", "--read-only", "--cap-drop", "ALL",
                    "--security-opt", "no-new-privileges", "--user", "65534", "--volume", source + ":" + target + ":ro",
                    "--", image, "/qa/busybox", "echo", "PR516_MOUNTED_SHELL_OK"]
        var original = AgentRuntimeProcessLaunchPlan(runtime: .codexCLI, executablePath: docker.executablePath, arguments: args,
                                                     currentDirectory: home, environment: docker.environment, browserShimDirectory: nil,
                                                     providerVersion: nil, parsesJSONLines: false,
                                                     executionEnvironment: .init(id: "mounted-shell", kind: .dockerImage, displayName: "QA", image: image,
                                                                                 providerPlacement: .container, mounts: [mount], networkMode: "none", user: "65534"))
        original.containerProviderCommandIndex = args.count - 3
        let prepared = await RuntimeHomeAccessContainerPreflight.prepare(original, resumeSessionID: nil)
        #expect(prepared.arguments == original.arguments)
        #expect(prepared.commandPlannedFields["provider_home_access_check"] == "not_checked_shell_probe_failed")
        let result = await ProcessBinaryRunner().run(path: prepared.executablePath, args: prepared.arguments, timeout: 15, environment: prepared.environment)
        #expect(result.isSuccess, "\(result.stderr)")
        #expect(result.stdout == "PR516_MOUNTED_SHELL_OK\n")
    }

    @Test("A missing top-level container home is judged against root, not the workspace", arguments: [AgentRuntimeID.claudeCode, .copilotCLI, .codexCLI])
    func topLevelContainerHome(runtime: AgentRuntimeID) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let variable = try #require(AgentRuntimeAdapterRegistry.homeAccessPolicy(for: runtime).roots.first?.variable)
        let result = try shell(runtime: runtime, home: home, environment: [variable: "/astra-missing-\(UUID().uuidString)"])
        #expect(result.exitCode == 78)
        #expect(result.stdout.isEmpty)
    }

    @Test("Copilot checks exactly the resumed container session without scanning other sessions")
    func resumedContainerSession() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let current = home + "/.copilot/session-state/resumed-session"
        let old = home + "/.copilot/session-state/unrelated-session"
        try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: old)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old)
        }
        #expect(try shell(runtime: .copilotCLI, home: home, resumeSessionID: "resumed-session").exitCode == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: current)
        let refused = try shell(runtime: .copilotCLI, home: home, resumeSessionID: "resumed-session")
        #expect(refused.exitCode == 78)
        #expect(refused.stdout.isEmpty)
        #expect(refused.stderr.contains("resumed-session"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current)
        #expect(try shell(runtime: .copilotCLI, home: home, resumeSessionID: "resumed-session").exitCode == 0)
    }

    @MainActor
    @Test("Shell capability is optional, bounded, and probed without invoking the provider", arguments: ["present", "missing", "timeout"])
    func optionalShellCapability(mode: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let original = try containerPlan(home: home)
        let outcome: RunResult = mode == "present" ? .exited(code: 0, stdout: "", stderr: "")
            : (mode == "missing" ? .exited(code: 127, stdout: "", stderr: "no /bin/sh") : .timedOut(stdout: "", stderr: ""))
        let record = ProbeRecord()
        let plan = await RuntimeHomeAccessContainerPreflight.prepare(original, resumeSessionID: nil, runner: ProbeRunner(result: outcome, record: record))
        let calls = await record.calls
        #expect(calls.count == 1)
        let arguments = try #require(calls.first)
        #expect(arguments.contains("--read-only"))
        #expect(arguments.contains("no-new-privileges"))
        #expect(arguments.contains("65534"))
        #expect(arguments.contains("none"))
        #expect(!arguments.contains("--volume"))
        #expect(!arguments.contains("--env"))
        #expect(!arguments.contains("/provider"))
        if mode == "present" {
            let index = try #require(plan.containerProviderCommandIndex)
            #expect(plan.arguments[index] == "/bin/sh")
            #expect(plan.commandPlannedFields["provider_home_access_check"] == "container")
        } else {
            #expect(plan.arguments == original.arguments)
            #expect(plan.commandPlannedFields["provider_home_access_check"] == "not_checked_shell_probe_failed")
        }
        #expect(plan.executionEnvironment == original.executionEnvironment)
        let index = try #require(original.containerProviderCommandIndex)
        #expect(Array(plan.arguments.prefix(index)) == Array(original.arguments.prefix(index)))
    }

    actor ProbeRecord {
        var calls: [[String]] = []
        func append(_ arguments: [String]) { calls.append(arguments) }
    }

    struct ProbeRunner: BinaryRunner {
        let result: RunResult
        let record: ProbeRecord
        private func assertBackgroundThread() { #expect(!Thread.isMainThread) }
        func run(path: String, args: [String], timeout: TimeInterval, environment: [String: String]?) async -> RunResult {
            assertBackgroundThread()
            #expect(timeout == 5)
            await record.append(args)
            return result
        }
    }

    @Test("OpenCode checks the effective database type and read/write access", arguments: ["default", "absolute", "relative", "directory", "read-only-parent", "search-only-parent"])
    func openCodeDatabase(mode: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var environment = ["HOME": home]
        let data = home + "/.local/share/opencode"
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        var database = data + "/opencode.db"
        let customParent = home + "/database-parent"
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: customParent) }
        if mode == "absolute" {
            database = home + "/custom database.db"
            environment["OPENCODE_DB"] = database
        } else if mode == "relative" {
            database = data + "/custom database.db"
            environment["OPENCODE_DB"] = "custom database.db"
        } else if mode == "read-only-parent" || mode == "search-only-parent" {
            try FileManager.default.createDirectory(atPath: customParent, withIntermediateDirectories: true)
            database = customParent + "/state.db"
            environment["OPENCODE_DB"] = database
        }
        if mode == "directory" {
            try FileManager.default.createDirectory(atPath: database, withIntermediateDirectories: false)
        } else {
            FileManager.default.createFile(atPath: database, contents: Data(), attributes: [.posixPermissions: 0])
        }
        if mode == "read-only-parent" { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: customParent) }
        if mode == "search-only-parent" { try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: customParent) }
        let request = RuntimeHomeAccessRequest(runtime: .openCodeCLI, policy: AgentRuntimeAdapterRegistry.homeAccessPolicy(for: .openCodeCLI),
                                               environment: environment, workingDirectory: home, userHome: home)
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
        #expect(try shell(runtime: .openCodeCLI, home: home, environment: environment).exitCode == 78)
        if mode == "directory" { try FileManager.default.removeItem(atPath: database) }
        FileManager.default.createFile(atPath: database, contents: Data(), attributes: [.posixPermissions: 0o400])
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: database)
        #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
        #expect(try shell(runtime: .openCodeCLI, home: home, environment: environment).exitCode == 78)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database)
        if mode == "read-only-parent" {
            #expect(await RuntimeHomeAccessService.check(request)?.state == .blocked)
            #expect(try shell(runtime: .openCodeCLI, home: home, environment: environment).exitCode == 78)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: customParent)
        }
        #expect(await RuntimeHomeAccessService.check(request)?.state != .blocked)
        #expect(try shell(runtime: .openCodeCLI, home: home, environment: environment).exitCode == 0)
    }

    @MainActor
    @Test("Real Docker runs every provider command with and without a shell",
          .enabled(if: ProcessInfo.processInfo.environment["ASTRA_LIVE_HOME_DOCKER"] == "1"),
          arguments: AgentRuntimeAdapterRegistry.runtimeIDs, ["shell", "minimal"])
    func realDockerCapability(runtime: AgentRuntimeID, flavor: String) async throws {
        let image = try #require(ProcessInfo.processInfo.environment[flavor == "shell" ? "ASTRA_HOME_SHELL_IMAGE" : "ASTRA_HOME_MINIMAL_IMAGE"])
        let docker = try #require(DockerRuntimeResolver.resolve(environment: RuntimeProcessEnvironment.enriched()))
        let arguments = ["run", "--rm", "--pull", "never", "--network", "none", "--read-only", "--cap-drop", "ALL",
                         "--security-opt", "no-new-privileges", "--user", "65534", "--env", "HOME=/home/astra",
                         "--tmpfs", "/home/astra:mode=1777", "--", image, "/bin/echo", "PR516_DOCKER_OK"]
        var plan = AgentRuntimeProcessLaunchPlan(runtime: runtime, executablePath: docker.executablePath, arguments: arguments,
                                                 currentDirectory: FileManager.default.temporaryDirectory.path, environment: docker.environment,
                                                 browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false,
                                                 executionEnvironment: .init(id: "live-test", kind: .dockerImage, displayName: "Live QA", image: image,
                                                                             providerPlacement: .container, networkMode: "none", user: "65534"))
        plan.containerProviderCommandIndex = arguments.count - 2
        let prepared = await RuntimeHomeAccessContainerPreflight.prepare(plan, resumeSessionID: nil)
        #expect(prepared.commandPlannedFields["provider_home_access_check"] == (flavor == "shell" ? "container" : "not_checked_shell_probe_failed"))
        let result = await ProcessBinaryRunner().run(path: prepared.executablePath, args: prepared.arguments, timeout: 15, environment: prepared.environment)
        #expect(result.isSuccess, "\(runtime.rawValue): \(result.stderr)")
        #expect(result.stdout == "PR516_DOCKER_OK\n")
    }

    @MainActor
    @Test("Docker planning preserves a direct provider command until shell capability is known")
    func directContainerCommand() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let plan = try containerPlan(home: home)
        let image = try #require(plan.arguments.firstIndex(of: "astra/provider:latest"))
        #expect(Array(plan.arguments.dropFirst(image + 1)) == ["/provider", "exec", "hello"])
    }

    @MainActor
    func containerPlan(home: String) throws -> AgentRuntimeProcessLaunchPlan {
        let task = AgentTask(title: "QA", goal: "QA", workspace: Workspace(name: "QA", primaryPath: home))
        let base = AgentRuntimeProcessLaunchPlan(runtime: .codexCLI, executablePath: "/unused/codex", arguments: ["exec", "hello"],
                                                currentDirectory: home, environment: ["HOME": home], browserShimDirectory: nil,
                                                providerVersion: nil, parsesJSONLines: true)
        let environment = WorkspaceExecutionEnvironment(id: "qa", kind: .dockerImage, displayName: "QA", image: "astra/provider:latest",
                                                        runtimeExecutablePath: "/provider", providerPlacement: .container, user: "65534")
        return try DockerExecutionPlanner.plan(base: base, environment: environment, task: task, runID: nil).get()
    }

    func temporaryHome() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("astra-home-edge-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func shell(runtime: AgentRuntimeID, home: String, environment: [String: String] = [:], resumeSessionID: String? = nil) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.arguments = ["-c", RuntimeHomeAccessContainerCommand.script(policy: AgentRuntimeAdapterRegistry.homeAccessPolicy(for: runtime), resumeSessionID: resumeSessionID),
                             "astra-home-preflight", "/usr/bin/printf", "provider-reached\\n"]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"].merging(environment) { _, value in value }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return .exited(code: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
