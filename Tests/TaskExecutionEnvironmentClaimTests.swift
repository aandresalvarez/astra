import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Admission claims for what a run reaches through its execution environment:
/// host folders a Docker environment mounts, and the remote folder of a
/// workspace SSH connection. Each test compares what admission holds with
/// what the launch is granted.
@Suite("Execution environment resource claims")
@MainActor
struct TaskExecutionEnvironmentClaimTests {
    // MARK: - Docker environment mounts

    @Test("A read-write environment mount is claimed exclusively and a read-only one shared")
    func mountsAreClaimedByAccess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let reference = try fixture.directory("reference-data")
        let task = try fixture.dockerTask("workspace", mounts: [mount(cache, .readWrite), mount(reference, .readOnly)])

        let claims = TaskExecutionResourceClaimResolver.claims(for: task)
        let docker = claims.filter { $0.kind == .docker }

        #expect(Set(docker) == [
            TaskExecutionResourceClaim(kind: .docker, key: cache, access: .exclusive),
            TaskExecutionResourceClaim(kind: .docker, key: reference, access: .shared)
        ])
        // The workspace claim still leads, and nothing claims the environment itself.
        #expect(claims.first?.kind == .workspace)
        #expect(!claims.contains { $0.key.contains("image:") })
    }

    @Test("Tasks on one environment wait for each other only where one can write a mount")
    func environmentIsNotABlanketLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let reference = try fixture.directory("reference-data")
        let otherCache = try fixture.directory("other-cache")
        func lease(_ name: String, _ mounts: [ExecutionEnvironmentMount]) throws -> [TaskResourceLockClaim] {
            fixture.lease(try fixture.dockerTask(name, mounts: mounts))
        }

        // Same environment, same writable host folder: one at a time.
        #expect(!TaskExecutionResourceBroker.canAcquire(
            try lease("b", [mount(cache, .readWrite)]), active: try lease("a", [mount(cache, .readWrite)])))
        // Same environment, read-only mounts: together.
        #expect(TaskExecutionResourceBroker.canAcquire(
            try lease("d", [mount(reference, .readOnly)]), active: try lease("c", [mount(reference, .readOnly)])))
        // Same environment ID, different writable folders: together.
        #expect(TaskExecutionResourceBroker.canAcquire(
            try lease("f", [mount(otherCache, .readWrite)]), active: try lease("e", [mount(cache, .readWrite)])))
        // A reader of a mount waits for a container that writes it, and the reverse.
        #expect(!TaskExecutionResourceBroker.canAcquire(
            try lease("h", [mount(cache, .readOnly)]), active: try lease("g", [mount(cache, .readWrite)])))
        #expect(!TaskExecutionResourceBroker.canAcquire(
            try lease("j", [mount(cache, .readWrite)]), active: try lease("i", [mount(cache, .readOnly)])))
        // A writable mount of a folder also holds what is inside it.
        let nested = try fixture.directory("shared-build-cache/objects")
        #expect(!TaskExecutionResourceBroker.canAcquire(
            try lease("l", [mount(nested, .readWrite)]), active: try lease("k", [mount(cache, .readWrite)])))
    }

    @Test("A writable mount competes with tasks that hold the folder as a workspace")
    func writableMountCompetesWithWorkspaceHolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = try fixture.directory("shared")
        let project = try fixture.directory("shared/project")

        let hostWriter = AgentTask(title: "Edit", goal: "Update the parser.",
                                   workspace: Workspace(name: "Host", primaryPath: project))
        let hostReader = AgentTask(title: "Read", goal: "Explain the parser.",
                                   workspace: Workspace(name: "Host reader", primaryPath: project))
        hostReader.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        let writableMount = fixture.lease(try fixture.dockerTask("a", mounts: [mount(project, .readWrite)]))
        let parentMount = fixture.lease(try fixture.dockerTask("b", mounts: [mount(shared, .readWrite)]))
        let readOnlyMount = fixture.lease(try fixture.dockerTask("c", mounts: [mount(project, .readOnly)]))

        for holder in [hostWriter, hostReader] {
            #expect(!TaskExecutionResourceBroker.canAcquire(writableMount, active: fixture.lease(holder)))
            #expect(!TaskExecutionResourceBroker.canAcquire(fixture.lease(holder), active: writableMount))
            // The container can write every project under the mounted folder.
            #expect(!TaskExecutionResourceBroker.canAcquire(parentMount, active: fixture.lease(holder)))
        }
        // A read-only mount is a reader that does not wait for workspace writers.
        #expect(TaskExecutionResourceBroker.canAcquire(readOnlyMount, active: fixture.lease(hostWriter)))
        #expect(TaskExecutionResourceBroker.canAcquire(fixture.lease(hostWriter), active: readOnlyMount))
    }

    @Test("A read-only run claims its mounts shared, and exclusively once sandboxing is Off")
    func readOnlyRunFollowsItsAdmittedAccess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let task = try fixture.dockerTask("workspace", mounts: [mount(cache, .readWrite)], readOnly: true)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                      resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))

        // Frozen as a reader: the launch downgrades the mount, so the claim is shared.
        #expect(request.resourceClaims.contains(TaskExecutionResourceClaim(kind: .docker, key: cache, access: .shared)))
        let enforced = fixture.lease(task, request: request)
        #expect(enforced.first { $0.resourceKind == .docker }?.accessMode == .readOnly)

        // With sandboxing Off the same request is admitted as a writer, and the
        // launch then keeps the mount read-write. The lease follows.
        let unenforced = fixture.lease(task, request: request, sandboxEnforcement: .off)
        #expect(TaskExecutionResourceAdmissionPolicy.workspaceAccess(from: unenforced) == .exclusive)
        #expect(unenforced.first { $0.resourceKind == .docker }?.accessMode == .write)
    }

    @Test("Every mount the launch plans is covered by what admission holds", arguments: [
        ExecutionSandboxEnforcement.bestEffort, .strict, .off
    ])
    func claimsAgreeWithTheLaunchMountPlan(enforcement: ExecutionSandboxEnforcement) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let reference = try fixture.directory("reference-data")
        let nestedInWorkspace = try fixture.directory("workspace/build")
        let mounts = [mount(cache, .readWrite), mount(reference, .readOnly), mount(nestedInWorkspace, .readWrite)]

        for readOnly in [false, true] {
            let task = try fixture.dockerTask("workspace", mounts: mounts, readOnly: readOnly)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                          resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
            let lease = fixture.lease(task, request: request, sandboxEnforcement: enforcement)
            // What the queue hands the worker, and the worker hands the launch.
            let access = try #require(TaskExecutionResourceAdmissionPolicy.workspaceAccess(from: lease))
            let workspacePath = try fixture.directory("workspace")
            let plan = TaskLaunchResourceResolver.resolve(
                task: task, runID: UUID(), runtime: .claudeCode, phase: "run",
                prompt: task.goal, contextText: "", workspacePath: workspacePath,
                executionEnvironment: DockerExecutionPlanner.snapshotForRun(
                    task: task, currentDirectory: workspacePath, workspaceAccess: access),
                workspaceAccess: access,
                gitCredentialContextProvider: { _, _, _, _ in .empty }
            )
            #expect(!plan.containerMounts.isEmpty)
            let taskFolder = TaskWorkspaceAccess(task: task).taskFolder

            for granted in plan.containerMounts {
                let host = TaskExecutionResourceBroker.canonicalKey(kind: .docker, key: granted.hostPath)
                let writable = granted.access == ExecutionEnvironmentMountAccess.readWrite.rawValue
                let covering = lease.filter { claim in
                    guard claim.resourceKind == .docker || claim.resourceKind == .workspace else { return false }
                    let key = TaskExecutionResourceBroker.canonicalKey(kind: claim.resourceKind, key: claim.resourceKey)
                    return host == key || host.hasPrefix(key + "/")
                }
                if host == TaskExecutionResourceBroker.canonicalKey(kind: .docker, key: taskFolder) { continue }
                let label = "\(granted.hostPath) \(granted.access) readOnly=\(readOnly) \(enforcement.rawValue)"
                if writable {
                    #expect(covering.contains { $0.accessMode == .write }, "unclaimed writable mount: \(label)")
                } else {
                    #expect(!covering.isEmpty, "unclaimed read-only mount: \(label)")
                }
            }
            // And the launch gate agrees with itself.
            #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
                request: request, task: task, lease: lease, workspaceAccess: access))
        }
    }

    @Test("A launch stops when its environment gained a writable mount after admission")
    func unadmittedWritableMountIsDrift() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let added = try fixture.directory("added-after-admission")
        let task = try fixture.dockerTask("workspace", mounts: [mount(cache, .readWrite)])
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                      resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
        let lease = fixture.lease(task, request: request)

        #expect(TaskExecutionResourceClaimResolver.unadmittedMounts(
            lease: lease, task: task, workspaceAccess: .exclusive).isEmpty)

        fixture.setEnvironment(task, mounts: [mount(cache, .readWrite), mount(added, .readWrite)])
        #expect(TaskExecutionResourceClaimResolver.unadmittedMounts(
            lease: lease, task: task, workspaceAccess: .exclusive) == [added])
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))
        // With or without a durable request.
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: nil, task: task, lease: lease, workspaceAccess: .exclusive))
        // A read-only mount added late is drift too: it needs a reader's claim
        // to wait for a container that writes the same folder.
        fixture.setEnvironment(task, mounts: [mount(cache, .readWrite), mount(added, .readOnly)])
        #expect(TaskExecutionResourceClaimResolver.unadmittedMounts(
            lease: lease, task: task, workspaceAccess: .exclusive) == [added])
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))
        // A read-only mount inside a folder the lease writes is covered by it.
        let inside = try fixture.directory("shared-build-cache/inside")
        fixture.setEnvironment(task, mounts: [mount(cache, .readWrite), mount(inside, .readOnly)])
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))
        // A launch with no lease to compare against is not judged here.
        fixture.setEnvironment(task, mounts: [mount(cache, .readWrite), mount(added, .readWrite)])
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: nil, workspaceAccess: .exclusive))
    }

    @Test("A task without a snapshot claims the environment its launch will settle")
    func missingSnapshotUsesTheWorkspaceEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let task = try fixture.dockerTask("workspace", mounts: [mount(cache, .readWrite)])
        task.workspace?.activeExecutionEnvironmentJSON = task.executionEnvironmentSnapshotJSON
        task.executionEnvironmentSnapshotJSON = nil
        task.status = .queued

        // `DockerExecutionPlanner.resolveEnvironment` answers Host for this
        // task; the launch settles the workspace's environment onto it.
        #expect(DockerExecutionPlanner.resolveEnvironment(for: task).isHost)
        #expect(TaskExecutionResourceClaimResolver.claims(for: task)
            .contains(TaskExecutionResourceClaim(kind: .docker, key: cache, access: .exclusive)))
    }

    @Test("Host tasks and mount-free environments claim no Docker resource")
    func noMountsNoClaim() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = AgentTask(title: "Edit", goal: "Update the parser.",
                             workspace: Workspace(name: "Host", primaryPath: try fixture.directory("host")))
        let bare = try fixture.dockerTask("workspace", mounts: [])
        // A mount of the task's own workspace root is the workspace claim's.
        let own = try fixture.dockerTask("own", mounts: [mount(try fixture.directory("own"), .readWrite)])
        for task in [host, bare, own] {
            #expect(!TaskExecutionResourceClaimResolver.claims(for: task).contains { $0.kind == .docker })
            #expect(!fixture.lease(task).contains { $0.resourceKind == .docker })
        }
    }

    // MARK: - Remote folders

    @Test("A launch judges and uses one read of the connections, whatever the file says later")
    func launchUsesOneConnectionsSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = try fixture.remoteTask("a", connection(path: "/srv/service-a"))
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                      resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
        let lease = fixture.lease(task, request: request)
        let path = try #require(task.workspace?.primaryPath)

        LaunchSSHConnectionSnapshot.pin(for: task)
        defer { LaunchSSHConnectionSnapshot.release(taskID: task.id) }
        // The file changes after the launch read it.
        SSHConnectionManager.save([connection(path: "/srv/service-b")], workspacePath: path)

        // The drift check and every launch reader see the pinned set, so the
        // check passes for exactly what the launch goes on to use.
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))
        #expect(LaunchSSHConnectionSnapshot.connections(for: task).map(\.remotePath) == ["/srv/service-a"])
        #expect(RemoteWorkspaceJobShim.offeredConnections(task: task, targets: ["deploy@release.example.com"]).count == 1)

        // Released, readers see the file again, and the next launch's check
        // stops on the folder its lease does not cover.
        LaunchSSHConnectionSnapshot.release(taskID: task.id)
        #expect(LaunchSSHConnectionSnapshot.connections(for: task).map(\.remotePath) == ["/srv/service-b"])
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))
    }

    @Test("A launch stops when the connections name a remote folder its lease does not cover")
    func unadmittedRemoteFolderIsDrift() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = try fixture.remoteTask("a", connection(path: "/srv/service-a"))
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                      resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
        let lease = fixture.lease(task, request: request)
        let path = try #require(task.workspace?.primaryPath)

        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))

        // The connections file changed between admission and launch.
        SSHConnectionManager.save([connection(path: "/srv/service-b")], workspacePath: path)
        #expect(TaskExecutionResourceClaimResolver.unadmittedRemoteDirectories(
            lease: lease, task: task, workspaceAccess: .exclusive) == ["release.example.com:22 /srv/service-b"])
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: nil, task: task, lease: lease, workspaceAccess: .exclusive))

        // A folder inside the one the lease writes is covered by it.
        SSHConnectionManager.save([connection(path: "/srv/service-a/releases")], workspacePath: path)
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: lease, workspaceAccess: .exclusive))

        // A reader's lease does not cover a launch that would write.
        SSHConnectionManager.save([connection(path: "/srv/service-a")], workspacePath: path)
        let readerLease = lease.map { claim in
            var copy = claim
            if copy.resourceKind == .remoteDirectory { copy.accessMode = .readOnly }
            return copy
        }
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request, task: task, lease: readerLease, workspaceAccess: .exclusive))
    }

    @Test("Independent remote folders and hosts run together")
    func independentRemoteFoldersRunTogether() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.remoteTask("a", connection(path: "/srv/service-a"))
        let second = try fixture.remoteTask("b", connection(path: "/srv/service-b"))
        let otherHost = try fixture.remoteTask("c", connection(host: "other.example.com", path: "/srv/service-a"))

        #expect(TaskExecutionResourceClaimResolver.claims(for: first).contains(TaskExecutionResourceClaim(
            kind: .remoteDirectory, key: "release.example.com:22 /srv/service-a", access: .exclusive)))
        #expect(TaskExecutionResourceBroker.canAcquire(fixture.lease(second), active: fixture.lease(first)))
        #expect(TaskExecutionResourceBroker.canAcquire(fixture.lease(otherHost), active: fixture.lease(first)))
    }

    @Test("Tasks on the same, a containing, or a contained remote folder wait, read-only or not", arguments: [
        ("/srv/service", "/srv/service"),
        ("/srv", "/srv/service"),
        ("/srv/service/releases", "/srv/service"),
        ("~/service", "service/"),
        ("~/service", "/srv/service")
    ])
    func overlappingRemoteFoldersConflict(firstPath: String, secondPath: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Two local workspaces: nothing but the remote folder is shared.
        let writer = try fixture.remoteTask("a", connection(path: firstPath))
        let otherWriter = try fixture.remoteTask("b", connection(path: secondPath))
        let reader = try fixture.remoteTask("c", connection(path: secondPath), readOnly: true)
        let otherReader = try fixture.remoteTask("d", connection(path: firstPath), readOnly: true)

        #expect(!TaskExecutionResourceBroker.canAcquire(fixture.lease(otherWriter), active: fixture.lease(writer)))
        #expect(!TaskExecutionResourceBroker.canAcquire(fixture.lease(reader), active: fixture.lease(writer)))
        #expect(!TaskExecutionResourceBroker.canAcquire(fixture.lease(writer), active: fixture.lease(reader)))
        // Nothing enforces read-only access over SSH, so a declared reader
        // holds the folder as a writer does.
        #expect(!TaskExecutionResourceBroker.canAcquire(fixture.lease(otherReader), active: fixture.lease(reader)))

        let conflict = try #require(TaskExecutionResourceBroker.firstConflict(
            requested: fixture.lease(otherWriter), active: fixture.lease(writer)))
        #expect(conflict.requested.resourceKind == .remoteDirectory)
        #expect(TaskExecutionResourceBroker.blockerSummary(
            requested: fixture.lease(otherWriter), active: fixture.lease(writer)
        ).hasPrefix("Waiting for remote folder "))
    }

    @Test("A declared remote reader holds the folder as a writer, with sandboxing on or Off")
    func remoteReaderHoldsTheFolderAsAWriter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = try fixture.remoteTask("a", connection(path: "/srv/service"), readOnly: true)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                      resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))

        #expect(fixture.lease(task, request: request).first { $0.resourceKind == .remoteDirectory }?.accessMode == .write)
        #expect(fixture.lease(task, request: request, sandboxEnforcement: .off)
            .first { $0.resourceKind == .remoteDirectory }?.accessMode == .write)
    }

    @Test("A request frozen before these claims existed still holds them at admission")
    func olderRequestsGainEnvironmentClaims() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.directory("shared-build-cache")
        let task = try fixture.dockerTask("workspace", mounts: [mount(cache, .readWrite)])
        SSHConnectionManager.save([connection(path: "/srv/service")], workspacePath: try fixture.directory("workspace"))
        let older = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: [
            TaskExecutionResourceClaim(kind: .workspace, key: try fixture.directory("workspace"), access: .exclusive)
        ])

        let lease = fixture.lease(task, request: older)
        #expect(lease.contains { $0.resourceKind == .docker && $0.accessMode == .write })
        #expect(lease.contains { $0.resourceKind == .remoteDirectory && $0.accessMode == .write })
        // A launch with no request is admitted the same way.
        let direct = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task, runMode: "test")
        #expect(Set(direct.map(\.resourceKind)).isSuperset(of: [.docker, .remoteDirectory]))
    }

    // MARK: - Local SSH state contract

    @Test("Each remote-workspace task's ssh uses its own known-hosts file, never the shared one")
    func sshWrapperIsolatesKnownHostsPerTask() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let fakeSSH = URL(fileURLWithPath: try fixture.directory("bin")).appendingPathComponent("real-ssh")
        try "#!/bin/sh\nexit 0\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let hostKnownHosts = URL(fileURLWithPath: try fixture.directory("home-ssh")).appendingPathComponent("known_hosts")
        let trusted = "release.example.com ssh-ed25519 AAAA\n"
        try trusted.write(to: hostKnownHosts, atomically: true, encoding: .utf8)

        var knownHostsFiles: [String] = []
        for name in ["a", "b"] {
            let task = try fixture.remoteTask(name, connection(path: "/srv/service"))
            if let workspace = task.workspace { container.mainContext.insert(workspace) }
            container.mainContext.insert(task)
            let shim = try #require(AgentRuntimeProcessRunner.prepareSSHShimIfNeeded(
                task: task, realSSHPath: fakeSSH.path, hostKnownHostsPath: hostKnownHosts.path))
            let script = try String(contentsOfFile: (shim as NSString).appendingPathComponent("ssh"), encoding: .utf8)
            let taskKnownHosts = (TaskWorkspaceAccess(task: task).taskFolder as NSString)
                .appendingPathComponent(".runtime-ssh/known_hosts")

            #expect(script.contains(taskKnownHosts))
            #expect(script.contains("GlobalKnownHostsFile=/dev/null"))
            #expect(script.contains("UpdateHostKeys=no"))
            #expect(!script.contains(hostKnownHosts.path))
            #expect(try String(contentsOfFile: taskKnownHosts, encoding: .utf8) == trusted)
            knownHostsFiles.append(taskKnownHosts)
        }
        // Two runs on one host never share a mutable known-hosts file on this
        // route, and preparing them wrote nothing to the shared one.
        #expect(Set(knownHostsFiles).count == 2)
        #expect(try String(contentsOf: hostKnownHosts, encoding: .utf8) == trusted)
    }

    @Test("Local SSH and gcloud state is granted without a claim: a recorded contract, not a lock")
    func localSSHStateIsAContractNotAClaim() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = URL(fileURLWithPath: try fixture.directory("home"))
        let ssh = URL(fileURLWithPath: try fixture.directory("home/.ssh"))
        try "release.example.com ssh-ed25519 AAAA\n".write(
            to: ssh.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let first = try fixture.remoteTask("a", connection(path: "/srv/service-a"))
        let second = try fixture.remoteTask("b", connection(path: "/srv/service-b"))

        let plan = TaskLaunchResourceResolver.resolve(
            task: first, runID: UUID(), runtime: .claudeCode, phase: "run", prompt: first.goal, contextText: "",
            workspacePath: first.workspace?.primaryPath ?? "", homeDirectoryPath: home.path,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
        // The grant is unchanged: tools that call /usr/bin/ssh directly need it.
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace && $0.access == .readWrite
                && $0.path == ssh.appendingPathComponent("known_hosts").standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace && $0.access == .write && $0.path == ssh.standardizedFileURL.path
        })
        // No claim names it, so two remote-workspace tasks on separate folders
        // are not serialized on ~/.ssh.
        for lease in [fixture.lease(first), fixture.lease(second)] {
            #expect(!lease.contains { $0.resourceKey.contains("/.ssh") || $0.resourceKey.contains("gcloud") })
        }
        #expect(TaskExecutionResourceBroker.canAcquire(fixture.lease(second), active: fixture.lease(first)))
        // The written contract this decision rests on.
        let document = try String(contentsOf: TestRepositoryRoot.resolve()
            .appendingPathComponent("docs/qa/2026-11-22-environment-resource-claims.md"), encoding: .utf8)
        #expect(document.contains("Local SSH state"))
        #expect(document.contains("UserKnownHostsFile"))
    }

    // MARK: - Fixture

    private func mount(_ hostPath: String, _ access: ExecutionEnvironmentMountAccess) -> ExecutionEnvironmentMount {
        ExecutionEnvironmentMount(
            hostPath: hostPath, containerPath: "/mnt/" + (hostPath as NSString).lastPathComponent,
            access: access, role: .additionalPath
        )
    }

    private func connection(host: String = "release.example.com", path: String) -> SSHConnection {
        SSHConnection(name: "release-box", host: host, user: "deploy", remotePath: path)
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-environment-claims-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func directory(_ relative: String) throws -> String {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.standardizedFileURL.path
        }

        @MainActor
        func setEnvironment(_ task: AgentTask, mounts: [ExecutionEnvironmentMount]) {
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
                id: "image:astra-environment-claims", kind: .dockerImage, displayName: "Claims image",
                image: "astra/claims:latest", mounts: mounts
            ))
        }

        @MainActor
        func dockerTask(_ workspace: String, mounts: [ExecutionEnvironmentMount], readOnly: Bool = false) throws -> AgentTask {
            let task = AgentTask(title: "Rebuild the artifacts", goal: "Update the build outputs.",
                                 workspace: Workspace(name: workspace, primaryPath: try directory(workspace)))
            if readOnly { task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"] }
            setEnvironment(task, mounts: mounts)
            return task
        }

        @MainActor
        func remoteTask(_ workspace: String, _ connection: SSHConnection, readOnly: Bool = false) throws -> AgentTask {
            let path = try directory(workspace)
            SSHConnectionManager.save([connection], workspacePath: path)
            let task = AgentTask(title: "Update the release script", goal: "Update the deployment script on the remote host.",
                                 workspace: Workspace(name: workspace, primaryPath: path))
            if readOnly { task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"] }
            return task
        }

        @MainActor
        func lease(
            _ task: AgentTask,
            request: TaskTurnRequest? = nil,
            sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
        ) -> [TaskResourceLockClaim] {
            let frozen = request ?? TaskTurnRequest(
                task: task, messageEventID: UUID(), sequence: 1,
                resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
            return TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: frozen, task: task, runMode: "test", sandboxEnforcement: sandboxEnforcement)
        }
    }
}
