import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Accepted execution resource scope")
@MainActor
struct TaskExecutionResourceScopeTests {
    private let runtimes: [AgentRuntimeID] = [
        .claudeCode, .copilotCLI, .codexCLI, .cursorCLI, .antigravityCLI, .openCodeCLI
    ]

    @Test("All provider pairs admit independent worktrees without granting the source checkout")
    func providerPairs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for firstRuntime in runtimes {
            for secondRuntime in runtimes {
                let first = fixture.task(root: fixture.first, runtime: firstRuntime)
                let second = fixture.task(root: fixture.second, runtime: secondRuntime)
                let firstScope = TaskExecutionResourceScopeResolver.resolve(task: first)
                let secondScope = TaskExecutionResourceScopeResolver.resolve(task: second)
                #expect(!conflicts(first, firstScope, second, secondScope))
                for (task, scope, runtime) in [(first, firstScope, firstRuntime), (second, secondScope, secondRuntime)] {
                    task.acceptedResourceScope = scope
                    let plan = launch(task, runtime: runtime, home: fixture.root)
                    #expect(scope.isValid)
                    #expect(scope.replacedCheckoutPaths == [fixture.repository.path])
                    #expect(!plan.hostWritablePaths.contains(fixture.repository.path))
                    #expect(!plan.hostWritablePaths.contains(fixture.workspace.primaryPath))
                    #expect(plan.hostWritablePaths.allSatisfy { scope.coversWrite(to: $0) })
                    #expect(plan.diagnostics.allSatisfy { $0.severity != .error })
                    #expect(!AgentRuntimeProcessRunner.runtimeWritablePaths(for: task).contains(fixture.repository.path))
                    #expect(!AgentRuntimeProcessRunner.copilotNativeDirectoryProjection(for: task)
                        .additionalDirectories.contains(fixture.repository.path))
                }
            }
        }
    }

    @Test("Intentional shared folders and explicit source writes still conflict")
    func intentionalWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = fixture.root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        fixture.workspace.additionalPaths.append(shared.path)
        let first = fixture.task(root: fixture.first)
        let second = fixture.task(root: fixture.second)
        #expect(conflicts(first, TaskExecutionResourceScopeResolver.resolve(task: first),
                          second, TaskExecutionResourceScopeResolver.resolve(task: second)))
        fixture.workspace.additionalPaths = [fixture.repository.path]
        first.constraints = ["ASTRA_RESOURCE_WRITE_PATH=\(fixture.repository.path)"]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: first)
        #expect(scope.resources.contains { $0.path == fixture.repository.path && $0.access == .exclusive })
        #expect(scope.replacedCheckoutPaths.isEmpty)
    }

    @Test("Git inspection stays read-only even when runtime context asks for more")
    func gitScopeCannotGrowAtLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: "git status")
        let plan = launch(task, runtime: .claudeCode, home: fixture.root, context: "Run git push and git commit")
        let metadata = try #require(task.acceptedResourceScope?.resources.first { $0.role == .gitMetadata })
        #expect(metadata.access == .shared)
        #expect(plan.hostProtectedWriteDenyPaths.contains(metadata.path))
        #expect(plan.requiresSharedWorkspaceBoundary)
        #expect(plan.gitCredentialSandboxContext.writablePaths.isEmpty)
        #expect(plan.gitCredentialSandboxContext.readablePaths.contains(metadata.path))
        #expect(try fixture.git(["--no-optional-locks", "status", "--porcelain"], at: fixture.first).isEmpty)

        let mutating = fixture.task(root: fixture.second)
        let mutationScope = TaskExecutionResourceScopeResolver.resolve(task: mutating, acceptedTurn: "git commit the fix")
        #expect(conflicts(task, try #require(task.acceptedResourceScope), mutating, mutationScope))
    }

    @Test("Request serialization freezes resources and never rewrites editable task settings")
    func durableScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceScope: scope)
        let encoded = try JSONEncoder().encode(request.snapshot)
        let restored = TaskTurnRequest(snapshot: try JSONDecoder().decode(TaskTurnRequestSnapshot.self, from: encoded), task: task)
        fixture.workspace.additionalPaths.append(fixture.root.path)
        task.executionRootPath = fixture.second.path
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: restored, from: task))
        let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(snapshot.resourceScope == scope)
        #expect(restored.resourceClaims == scope.claims)
        #expect(TaskWorkspaceAccess(task: frozen).codeWorkingDirectory == fixture.first.path)
        #expect(!TaskWorkspaceAccess(task: frozen).runtimeWritablePaths.contains(fixture.root.path))
        #expect(task.acceptedResourceScope == nil)
    }

    @Test("Readers retain task output writes without gaining execution-root writes")
    func readerOutputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let plan = launch(task, runtime: .codexCLI, home: fixture.root)
        #expect(plan.workspaceAccess == .shared)
        #expect(!plan.hostWritablePaths.contains(fixture.first.path))
        #expect(plan.hostWritablePaths.contains(TaskWorkspaceAccess(task: task).taskFolder))
        #expect(plan.requiresSharedWorkspaceBoundary)
    }

    @Test("Workspace readers share while task storage remains isolated from writers")
    func sharedReadersWithStorage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.workspace.additionalPaths = []
        let root = URL(fileURLWithPath: fixture.workspace.primaryPath)
        let first = fixture.task(root: root)
        let second = fixture.task(root: root)
        first.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        second.constraints = first.constraints
        let left = TaskExecutionResourceScopeResolver.resolve(task: first)
        let right = TaskExecutionResourceScopeResolver.resolve(task: second)
        #expect(!conflicts(first, left, second, right))
        #expect(left.coversWrite(to: TaskWorkspaceAccess(task: first).taskFolder))
        #expect(!left.coversWrite(to: TaskWorkspaceAccess(task: second).taskFolder))
        second.constraints = []
        #expect(conflicts(first, left, second, TaskExecutionResourceScopeResolver.resolve(task: second)))
    }

    @Test("Docker mounts preserve custom write claims and overlay read-only Git metadata")
    func dockerScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.repository)
        let custom = fixture.root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let environment = WorkspaceExecutionEnvironment(
            id: "scope-image", kind: .dockerImage, displayName: "Scope", image: "test:latest",
            mounts: [.init(hostPath: custom.path, containerPath: "/custom", access: .readWrite, role: .additionalPath)])
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        task.acceptedResourceScope = scope
        let mounts = DockerExecutionPlanner.mountPlan(currentDirectory: fixture.repository.path,
            environment: environment, task: task)
        #expect(scope.claims.contains { $0.key == custom.path && $0.access == .exclusive })
        #expect(mounts.contains { $0.hostPath == custom.path && $0.access == .readWrite })
        let gitPath = fixture.repository.appendingPathComponent(".git").path
        #expect(mounts.contains {
            $0.hostPath == gitPath && $0.containerPath == environment.containerWorkingDirectory + "/.git"
                && $0.access == .readOnly
        })
        #expect(mounts.filter { $0.access == .readWrite }.allSatisfy { scope.coversWrite(to: $0.hostPath) })
    }

    @Test("An accepted symlink identity cannot silently move to another folder")
    func symlinkDrift() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.first)
        let task = fixture.task(root: alias)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        #expect(scope.isValid)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.second)
        #expect(!scope.isValid)
    }

    @Test("Replacing a checkout alias freezes the original source identity")
    func replacedCheckoutIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repository)
        fixture.workspace.additionalPaths = [alias.path]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: fixture.task(root: fixture.first))
        #expect(scope.replacedCheckoutPaths == [fixture.repository.path])
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.second)
        #expect(scope.isValid)
        #expect(scope.replacedCheckoutPaths == [fixture.repository.path])
    }

    @Test("The enforced inspection boundary allows edits but denies shared Git writes")
    func enforcedGitInspection() throws {
        let fixture = try Fixture(base: TestRepositoryRoot.resolve().appendingPathComponent(".build"))
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let resourcePlan = launch(task, runtime: .claudeCode, home: fixture.root)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["HOME"] = fixture.root.path
        let processPlan = AgentRuntimeProcessLaunchPlan(
            runtime: .claudeCode, executablePath: "/bin/sh",
            arguments: ["-c", """
                /usr/bin/git --no-optional-locks status --porcelain >/dev/null || exit 11
                /usr/bin/touch scope-edit || exit 12
                if /usr/bin/git update-ref refs/heads/unadmitted HEAD 2>/dev/null; then exit 13; fi
                if /usr/bin/touch "$1/escaped" 2>/dev/null; then exit 14; fi
                """, "scope-test", fixture.repository.path],
            currentDirectory: fixture.first.path, environment: environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false,
            sandboxReadablePaths: resourcePlan.hostReadablePaths,
            sandboxProtectedWriteDenyPaths: resourcePlan.hostProtectedWriteDenyPaths)
        let decision = ExecutionSandbox.decide(plan: processPlan, providerHomeDirectory: fixture.root.path,
            additionalWritablePaths: resourcePlan.hostWritablePaths,
            additionalReadablePaths: resourcePlan.hostReadablePaths,
            resourceScope: resourcePlan.resourceScope,
            settings: ExecutionSandboxSettings(enforcement: .strict, wrappedRuntimes: [.claudeCode], allowNetwork: false))
        guard case .applied(let sandboxed, _) = decision else {
            Issue.record("Expected an enforced scope, got \(decision)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxed.executablePath)
        process.arguments = sandboxed.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxed.currentDirectory)
        process.environment = sandboxed.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.first.appendingPathComponent("scope-edit").path))
    }

    @Test("Read-only execution denies ambient temporary writes but permits owned output")
    func enforcedReaderOutput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.workspace.additionalPaths = []
        let task = fixture.task(root: URL(fileURLWithPath: fixture.workspace.primaryPath))
        task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let output = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let resources = launch(task, runtime: .claudeCode, home: fixture.root)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: "/bin/sh",
            arguments: ["-c", """
                /usr/bin/touch "$1/allowed" || exit 11
                if /usr/bin/touch forbidden 2>/dev/null; then exit 12; fi
                """, "scope-reader", output],
            currentDirectory: fixture.workspace.primaryPath, environment: ProcessInfo.processInfo.environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let decision = ExecutionSandbox.decide(plan: plan, providerHomeDirectory: fixture.root.path,
            additionalWritablePaths: resources.hostWritablePaths, additionalReadablePaths: resources.hostReadablePaths,
            workspaceWritable: false, resourceScope: resources.resourceScope,
            settings: ExecutionSandboxSettings(enforcement: .strict, wrappedRuntimes: [.claudeCode], allowNetwork: false))
        guard case .applied(let sandboxed, _) = decision else {
            Issue.record("Expected a confined reader, got \(decision)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxed.executablePath)
        process.arguments = sandboxed.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxed.currentDirectory)
        process.environment = sandboxed.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: output + "/allowed"))
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.primaryPath + "/forbidden"))
    }

    @Test("Hooks and subagent permissions are launch settings, never workspace mutations")
    func isolatedHookSettings() throws {
        let hooks = #"{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hook"}]}]}"#
        let json = try ClaudeSettingsStore.launchSettingsJSON(hooksJSON: hooks, policy: .restricted, allowedTools: ["Read"])
        let settings = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(settings["hooks"] != nil)
        #expect(settings["permissions"] != nil)
        #expect(throws: (any Error).self) {
            try ClaudeSettingsStore.launchSettingsJSON(hooksJSON: "{", policy: .restricted, allowedTools: [])
        }
    }

    private func launch(_ task: AgentTask, runtime: AgentRuntimeID, home: URL, context: String = "") -> TaskLaunchResourcePlan {
        TaskLaunchResourceResolver.resolve(task: task, runID: nil, runtime: runtime, phase: "run",
            prompt: task.goal, contextText: context, workspacePath: TaskWorkspaceAccess(task: task).codeWorkingDirectory,
            homeDirectoryPath: home.path, gitCredentialContextProvider: { _, _, _, _ in .empty })
    }

    private func conflicts(_ first: AgentTask, _ left: TaskExecutionResourceScope,
                           _ second: AgentTask, _ right: TaskExecutionResourceScope) -> Bool {
        !TaskExecutionResourceBroker.canAcquire(
            TaskExecutionResourceBroker.lockClaims(for: left.claims, taskID: first.id, requestID: nil, runMode: "test"),
            active: TaskExecutionResourceBroker.lockClaims(for: right.claims, taskID: second.id, requestID: nil, runMode: "test"))
    }

    private struct Fixture {
        let root: URL
        let repository: URL
        let first: URL
        let second: URL
        let workspace: Workspace

        init(base: URL = FileManager.default.temporaryDirectory) throws {
            root = base.appendingPathComponent("astra-scope-\(UUID().uuidString)")
            repository = root.appendingPathComponent("source")
            first = root.appendingPathComponent("first")
            second = root.appendingPathComponent("second")
            workspace = Workspace(name: "Scope", primaryPath: root.appendingPathComponent("workspace").path,
                                  additionalPaths: [repository.path])
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
            _ = try git(["init", "-q"], at: repository)
            _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "commit", "-qm", "Initial", "--allow-empty"], at: repository)
            _ = try git(["worktree", "add", "-qb", "first", first.path], at: repository)
            _ = try git(["worktree", "add", "-qb", "second", second.path], at: repository)
        }

        func task(root: URL, runtime: AgentRuntimeID = .claudeCode) -> AgentTask {
            let task = AgentTask(title: "Edit", goal: "Update the parser", workspace: workspace, runtime: runtime)
            task.executionRootPath = root.path
            return task
        }

        func git(_ arguments: [String], at directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ScopeGitFixture", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
            }
            return String(decoding: data, as: UTF8.self)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
