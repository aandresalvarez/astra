import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport
import WorkspaceToolSupport
@testable import ASTRA

/// The app's half of SSH remote jobs: the helper is on PATH only where
/// `ssh <target> '<command>'` already works, the run line offers it only
/// once it is there, and the policy guard denies a job whose ssh form it
/// would deny (docs/specs/2026-10-21-ssh-remote-managed-jobs.md).
@Suite("Remote workspace job shim")
@MainActor
struct RemoteWorkspaceJobShimTests {
    @Test("A native-shell route gets the shim for its own targets, and the run line offers it")
    func nativeShellRouteWritesShim() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let route = RemoteWorkspaceSSHRoute(targets: ["pcornet-backup"], route: .nativeShell)

        let prepared = try #require(RemoteWorkspaceJobShim.prepare(
            task: fixture.task, runID: fixture.runID, route: route, helperPath: fixture.helper.path
        ))
        #expect(prepared.remoteJobs)
        #expect(FileManager.default.isExecutableFile(atPath: fixture.shimPath))
        let script = try String(contentsOfFile: fixture.shimPath, encoding: .utf8)
        #expect(script.contains("export ASTRA_REMOTE_JOB_ROOT='\(fixture.taskFolder)/remote-jobs'"))
        #expect(script.contains("export ASTRA_REMOTE_JOB_SSH='\(fixture.taskFolder)/.runtime-bin/ssh'"))
        #expect(script.contains("export ASTRA_REMOTE_JOB_RUN_ID='\(fixture.runID.uuidString)'"))
        #expect(script.contains("exec '\(fixture.helper.path)' \"$@\""))
        // The staging connection was not in the route, so it is not offered.
        #expect(script.contains("pcornet-backup"))
        #expect(!script.contains("staging-box"))

        let guidance = prepared.runGuidance
        #expect(guidance.contains("astra-workspace-job start --connection pcornet-backup --label '<short label>' -- '<command>'"))
        #expect(guidance.contains("end your turn and give the user its remote_job_id"))
        #expect(guidance.contains("ASTRA does not resume this task by itself"))
        // Not part of the signature: offering the helper never drops a native session.
        #expect(prepared.signatureComponent == route.signatureComponent)
    }

    @Test("Every other route removes a stale shim and offers nothing", arguments: [
        HostControlSSHRoute.brokerReachabilityOnly,
        .unavailable(.policyDeniesShell),
        .unavailable(.shellSandboxBlocksNetwork)
    ])
    func otherRoutesRemoveShim(route: HostControlSSHRoute) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = RemoteWorkspaceJobShim.prepare(
            task: fixture.task, runID: fixture.runID,
            route: RemoteWorkspaceSSHRoute(targets: ["pcornet-backup"], route: .nativeShell),
            helperPath: fixture.helper.path
        )
        #expect(FileManager.default.fileExists(atPath: fixture.shimPath))

        let prepared = try #require(RemoteWorkspaceJobShim.prepare(
            task: fixture.task, runID: fixture.runID,
            route: RemoteWorkspaceSSHRoute(targets: ["pcornet-backup"], route: route),
            helperPath: fixture.helper.path
        ))
        #expect(!prepared.remoteJobs)
        #expect(!FileManager.default.fileExists(atPath: fixture.shimPath))
        #expect(!prepared.runGuidance.contains("astra-workspace-job"))
    }

    @Test("No installed helper, or no offered target, means no shim")
    func missingHelperOrTargetOffersNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missingHelper = RemoteWorkspaceJobShim.prepare(
            task: fixture.task, runID: fixture.runID,
            route: RemoteWorkspaceSSHRoute(targets: ["pcornet-backup"], route: .nativeShell),
            helperPath: fixture.root.appendingPathComponent("not-installed").path
        )
        #expect(missingHelper?.remoteJobs == false)
        let unknownTarget = RemoteWorkspaceJobShim.prepare(
            task: fixture.task, runID: fixture.runID,
            route: RemoteWorkspaceSSHRoute(targets: ["some-other-host"], route: .nativeShell),
            helperPath: fixture.helper.path
        )
        #expect(unknownTarget?.remoteJobs == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.shimPath))
        #expect(RemoteWorkspaceJobShim.prepare(task: fixture.task, runID: fixture.runID, route: nil, helperPath: fixture.helper.path) == nil)
    }

    @Test("The shim's connection list is the wire format the helper reads")
    func connectionsWireFormat() throws {
        let fixture = try Fixture(aliasLess: true)
        defer { fixture.cleanup() }
        let offered = RemoteWorkspaceJobShim.offeredConnections(task: fixture.task, targets: ["-p 2222 -i '/keys/my key' agent@vm.example.test"])
        let configuration = try RemoteWorkspaceJobConfiguration.fromEnvironment([
            RemoteWorkspaceJobConfiguration.recordRootKey: "/tmp/records",
            RemoteWorkspaceJobConfiguration.sshExecutableKey: "/tmp/ssh",
            RemoteWorkspaceJobConfiguration.connectionsKey: RemoteWorkspaceJobShim.connectionsJSON(offered)
        ])
        let connection = try #require(configuration.connections.first)
        #expect(configuration.connections.count == 1)
        #expect(connection.target == "-p 2222 -i '/keys/my key' agent@vm.example.test")
        #expect(connection.arguments == ["-p", "2222", "-i", "/keys/my key", "agent@vm.example.test"])
        #expect(connection.id == offered.first?.id)
    }

    @Test("The route survives the manifest's wire format with or without the helper")
    func routeCodable() throws {
        for route in [
            RemoteWorkspaceSSHRoute(targets: ["a"], route: .nativeShell, remoteJobs: true),
            RemoteWorkspaceSSHRoute(targets: ["a"], route: .nativeShell)
        ] {
            let data = try JSONEncoder().encode(route)
            #expect(try JSONDecoder().decode(RemoteWorkspaceSSHRoute.self, from: data) == route)
        }
        let legacy = try JSONDecoder().decode(RemoteWorkspaceSSHRoute.self, from: Data(#"{"targets":["a"],"route":"native_shell"}"#.utf8))
        #expect(!legacy.remoteJobs)
        #expect(!RemoteWorkspaceSSHRoute(targets: ["a"], route: .brokerReachabilityOnly, remoteJobs: true).remoteJobs)
    }

    // MARK: - Policy guard

    @Test("A job start is denied exactly where its ssh form is denied")
    func guardDeniesWhatSSHWouldDeny() {
        let start = "astra-workspace-job start --connection pcornet-backup --label 'scan' -- 'sas run.sas'"
        let denySSH = AgentPolicy(level: .custom, allowedTools: ["Read", "Bash"], allowedShellPatterns: ["*"], deniedShellPatterns: ["ssh:*"])
        let denyTool = AgentPolicy(level: .custom, allowedTools: ["Read", "Bash"], deniedTools: ["Bash(ssh:*)"], allowedShellPatterns: ["*"])
        for policy in [denySSH, denyTool] {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(policy: policy))
            #expect(guardrail.disposition(toolName: "Bash", command: "ssh pcornet-backup 'sas run.sas'") == .denied)
            #expect(guardrail.disposition(toolName: "Bash", command: start) == .denied, "\(policy.deniedShellPatterns + policy.deniedTools)")
            #expect(guardrail.disposition(toolName: "Bash", command: "astra-workspace-job status 0b0e0c9e-6f43-4d4e-9d53-2a3f7b7a1c11") != AgentRuntimePolicyGuard.CommandDisposition.denied)
        }
        // Ask asks before the helper as it asks before ssh; Auto runs both.
        let ask = AgentRuntimePolicyGuard(manifest: Self.manifest(policy: .preset(.review)))
        #expect(ask.disposition(toolName: "Bash", command: start) == .ask)
        let auto = AgentRuntimePolicyGuard(manifest: Self.manifest(policy: .preset(.autonomous)))
        #expect(auto.disposition(toolName: "Bash", command: start) == auto.disposition(toolName: "Bash", command: "ssh pcornet-backup 'sas run.sas'"))
    }

    @Test("The guard reads any job start as its ssh form, wherever it sits in the command")
    func sshEquivalentParsing() {
        let equivalent = RemoteWorkspaceJobPolicyEquivalence.sshEquivalent
        #expect(equivalent("astra-workspace-job start --connection box -- 'sudo rm -rf /data'") == "ssh box 'sudo rm -rf /data'")
        #expect(equivalent("astra-workspace-job start --connection=box --timeout 60 -- ls -la") == "ssh box ls -la")
        #expect(equivalent("astra-workspace-job start -- 'bq load x'") == "ssh 'bq load x'")
        #expect(equivalent("cd /tmp && ./.runtime-bin/astra-workspace-job start --label x -- 'gsutil rsync a b'") == "ssh 'gsutil rsync a b'")
        #expect(equivalent("astra-workspace-job status 123") == nil)
        #expect(equivalent("echo astra-workspace-job-start -- x") == nil)
    }

    // MARK: - Fixtures

    private static func manifest(policy: AgentPolicy) -> RunPermissionManifest {
        let runtime = AgentRuntimeID.claudeCode
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: runtime)
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            workspacePath: "/tmp/astra-remote-job-policy",
            additionalPaths: [],
            requestedAllowedTools: ["Read", "Grep"],
            localToolCommands: [],
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )
        return RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "run",
            providerID: runtime,
            providerVersion: nil,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            policyLevel: policy.level,
            policyScope: .builtInDefault,
            providerRender: adapter.render(policy: policy, context: context),
            workspacePath: "/tmp/astra-remote-job-policy",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: []
        )
    }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let root: URL
        let helper: URL
        let task: AgentTask
        let runID = UUID()

        init(aliasLess: Bool = false) throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            let context = container.mainContext
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-remote-job-shim-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            helper = root.appendingPathComponent("astra-workspace-job")
            try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

            let workspace = Workspace(name: "Remote jobs", primaryPath: root.path)
            context.insert(workspace)
            SSHConnectionManager.save(aliasLess ? [
                SSHConnection(name: "vm", host: "vm.example.test", user: "agent", port: 2222, keyPath: "/keys/my key")
            ] : [
                SSHConnection(name: "backup", host: "10.0.0.5", user: "alvaro", configAlias: "pcornet-backup"),
                SSHConnection(name: "staging", host: "10.0.0.6", user: "alvaro", configAlias: "staging-box")
            ], workspacePath: root.path)
            task = AgentTask(title: "Remote job", goal: "Run the SAS scan on the VM", workspace: workspace)
            context.insert(task)
            try context.save()
        }

        var taskFolder: String { TaskWorkspaceAccess(task: task).taskFolder }
        var shimPath: String { "\(taskFolder)/.runtime-bin/astra-workspace-job" }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
