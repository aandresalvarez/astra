import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Provider reservation launch boundary", .serialized)
@MainActor
struct ProviderSharedStateLaunchTests {
    @Test("Retargeting settings during the supervision baseline cannot launch or debit an attempt")
    func retargetDuringBaseline() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let first = h.rootURL.appendingPathComponent("first")
        let second = h.rootURL.appendingPathComponent("second")
        let link = h.workspaceURL.appendingPathComponent(".gemini")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        task.status = .running
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        let limits = owner.record.limits
        let entered = AgentLockedBuffer()
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.configureExecutionOwner(owner)
        defer { runner.configureExecutionOwner(nil) }
        runner.configureSupervision(.init(goal: "Synthetic", runtime: "antigravity_cli", taskFolder: h.rootURL.path,
            remoteCoverage: "Local fixture", investigator: { _ in .inconclusive("Unused") }, report: { _ in },
            collector: {
                do {
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
                    entered.append("retargeted")
                } catch { Issue.record("Fixture could not retarget: \(error)") }
                return .init(unavailable: "Synthetic baseline")
            }))
        let result = await runner.runRuntimeProcess(adapter: ReservationLaunchFixtureAdapter(),
            prompt: "Synthetic", task: task, workspacePath: h.workspaceURL.path, executablePath: "/bin/sh",
            homeDirectory: h.workspaceURL.path, permissionPolicy: .restricted, timeoutSeconds: 10,
            maxRunSeconds: 60, onLine: { _, _ in })
        #expect(entered.value == "retargeted")
        #expect(result.runtimeStopReason == RuntimeProviderResourceRegistry.Block.stopReason)
        #expect(!FileManager.default.fileExists(atPath: h.workspaceURL.appendingPathComponent("launched").path))
        #expect(owner.record.providerLaunchCount == 0 && owner.record.providerProcess == nil)
        #expect(owner.record.limits.turnsRemaining == limits.turnsRemaining)
        #expect(owner.record.limits.tokensSpent == limits.tokensSpent)
        #expect(owner.record.limits.secondsRemaining <= limits.secondsRemaining)
    }

    @Test("An inherited home never becomes a broad task or utility permission grant", arguments: ["", " \n "])
    func inheritedHomePermissions(configuredHome: String) throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configured = try ProviderSharedStateIdentity.providerHome(configuredHome)
        #expect(configured.isEmpty)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .antigravityCLI, executablePath: "/usr/bin/false",
            arguments: [], currentDirectory: h.workspaceURL.path, environment: ["HOME": home],
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .strict) }
        guard case .plan(let utility) = runner.sandboxedUtilityPlan(.init(process: plan,
            providerHomeDirectory: configured, permissionPolicy: .restricted, timeoutSeconds: 5)) else {
            Issue.record("Utility did not receive an enforced plan"); return
        }
        let utilityReceipt = try #require(utility.process.executionSandboxBoundaryReceipt)
        let canonicalHome = try #require(ExecutionSandbox.canonicalize(home))
        #expect(!utilityReceipt.writableRoots.contains(canonicalHome))
        #expect(!utilityReceipt.readableRoots.contains(canonicalHome))
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let context = AgentRuntimeProcessLaunchContext(prompt: "Synthetic", task: task, workspacePath: h.workspaceURL.path,
            executablePath: "/usr/bin/false", providerHomeDirectory: configured, permissionPolicy: .restricted,
            executionPolicy: .default, permissionManifest: nil, timeoutSeconds: 5)
        guard case .plan(let taskPlan) = runner.sandboxedPlan(adapter: ReservationLaunchFixtureAdapter(home: home), context: context) else {
            Issue.record("Task did not receive an enforced plan"); return
        }
        let taskReceipt = try #require(taskPlan.executionSandboxBoundaryReceipt)
        #expect(!taskReceipt.writableRoots.contains(canonicalHome))
        #expect(!taskReceipt.writableRoots.contains(canonicalHome + "/.cache"))
        #expect(!taskReceipt.writableRoots.contains(canonicalHome + "/Library/Caches"))
    }

    @Test("A configured home retains its explicit permissions and utilities retain the reserved key")
    func explicitHomeAndUtilityIdentity() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let home = try ProviderSharedStateIdentity.providerHome(h.rootURL.appendingPathComponent("profile").path)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home))
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .antigravityCLI, executablePath: "/usr/bin/false",
            arguments: [], currentDirectory: h.workspaceURL.path, environment: ["HOME": home],
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .strict) }
        guard case .plan(let wrapped) = runner.sandboxedUtilityPlan(.init(process: plan,
            providerHomeDirectory: home, permissionPolicy: .restricted, timeoutSeconds: 5, sharedStateKey: key)) else {
            Issue.record("Explicit home did not receive an enforced plan"); return
        }
        #expect(wrapped.sharedStateKey == key)
        #expect(try #require(wrapped.process.executionSandboxBoundaryReceipt).writableRoots.contains(home))
    }

    @Test("The reserved home follows scoped HOME without turning it into an explicit grant")
    func scopedHomeIsPinned() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let home = h.rootURL.appendingPathComponent("profile")
        let alias = h.rootURL.appendingPathComponent("profile-alias")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let skill = Skill(name: "Synthetic provider environment", environmentVariables: ["HOME": alias.path])
        h.context.insert(skill); task.skills = [skill]
        var context = AgentRuntimeProcessLaunchContext(prompt: "Synthetic", task: task, workspacePath: h.workspaceURL.path,
            executablePath: h.rootURL.appendingPathComponent("nonexistent-provider").path, providerHomeDirectory: "",
            permissionPolicy: .restricted, executionPolicy: .default, permissionManifest: nil, timeoutSeconds: 5)
        #expect(context.capabilityResolutionSnapshot.providerLaunch.resolver.resolvedEnvironmentVariables["HOME"] == alias.path)
        context.sharedStateHome = try context.antigravityLaunchHome()
        let adapter = AntigravityCLIRuntimeAdapter()
        context.sharedStateKey = try adapter.sharedLaunchStateKey(context: context)
        let plan = adapter.makeProcessLaunchPlan(context: context)
        #expect(context.providerHomeDirectory.isEmpty)
        #expect(plan.environment["HOME"] == (try ProviderSharedStateIdentity.canonicalPath(home.path)))
        try plan.validateSharedConfiguration(context.sharedStateKey)
        #expect(!FileManager.default.fileExists(atPath: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home.path).path))
    }

    @Test("A utility revalidates its reserved configuration at the actual process boundary")
    func utilityFinalBoundary() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let home = h.rootURL.appendingPathComponent("profile")
        let replacement = h.rootURL.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home.path))
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .antigravityCLI, executablePath: "/bin/sh",
            arguments: ["-c", "printf launched > launched"], currentDirectory: h.workspaceURL.path,
            environment: ["HOME": home.path], browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".gemini"), withDestinationURL: replacement)
        let result = await AgentRuntimeProcessRunner.runScopedUtilityProcess(plan, sharedStateKey: key,
            timeoutSeconds: 5, stdoutLineHandler: nil, stderrChunkHandler: nil,
            completion: { .init(exitCode: $0, output: $1, error: $2) },
            launchError: { .init(exitCode: -1, output: "", error: $0) },
            timeoutResult: { _ in .init(exitCode: -2, output: "", error: "Timed out") })
        #expect(result.exitCode == -1 && result.error.contains("configuration path changed"))
        #expect(!FileManager.default.fileExists(atPath: h.workspaceURL.appendingPathComponent("launched").path))
    }
}

private struct ReservationLaunchFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    var home: String? = nil
    var id: AgentRuntimeID { .antigravityCLI }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func sharedLaunchStateKey(context: AgentRuntimeProcessLaunchContext) throws -> AgentRuntimeSharedStateKey? {
        try AntigravityCLIRuntimeAdapter().sharedLaunchStateKey(context: context)
    }
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        .init(runtime: id, executablePath: "/bin/sh", arguments: ["-c", "printf launched > launched"],
              currentDirectory: context.workspacePath, environment: ["HOME": home ?? context.providerHomeDirectory],
              browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
    }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] { [] }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
