import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Claim-coverage fitness for `TaskExecutionResourceKind`.
///
/// `TaskExecutionResourceKind` declares the resource identities ASTRA is
/// willing to serialize on, but declaring a kind does nothing on its own: a
/// kind only affects admission once `TaskExecutionResourceClaimResolver`
/// actually emits a claim for it. `.gitCommonDirectory` shipped declared but
/// never emitted, and a reviewer had to find that by reading the diff.
///
/// These tests make the *whole* pattern checkable instead of one instance at a
/// time. Every declared kind must be either
///   (a) emitted by the real resolver in a reachable scenario, or
///   (b) named in `knownUnclaimedKinds` below with a written reason and the
///       concrete race it leaves open.
/// A newly added kind belongs to neither set, so it fails until someone makes
/// a conscious decision. An allowlisted kind that starts being emitted also
/// fails, so the allowlist cannot rot into a lie.
@Suite("Task execution resource claim coverage")
@MainActor
struct TaskExecutionResourceClaimCoverageTests {
    /// Kinds ASTRA declares but does **not** claim today.
    ///
    /// Each entry states why no claim exists and what concurrent runs can
    /// therefore race on. These are tracked gaps, not approved designs: the
    /// documenting tests further down pin the current behavior so that fixing
    /// a gap fails loudly here and forces this list to shrink.
    private static let knownUnclaimedKinds: Set<TaskExecutionResourceKind> = [
        // No per-session identity exists to claim: ASTRA's browser bridge is a
        // single process-wide `ShelfBrowserBridgeRegistry.shared` that holds
        // one endpoint and one bound `taskID` at a time, and
        // `TaskLaunchResourceResolver` only records a `browser_bridge`
        // provider requirement / control-plane resource for a task. Risk: two
        // concurrent browser tasks are admitted together and fight over one
        // bridge binding (whichever binds last owns the session).
        .browserSession,
        // Per-task Docker state (container name, `DOCKER_CONFIG` directory) is
        // already task/run scoped, so the unclaimed part is the *environment*:
        // `WorkspaceExecutionEnvironment.mounts` and `credentialProjections`
        // project the same host paths into every container using that
        // environment, `rw` included. Risk: two runs sharing one environment
        // write the same host directory through their containers with nothing
        // serializing them (see `dockerEnvironmentMountsAreGrantedWritableWithoutADockerClaim`).
        .docker,
        // The remote host, its working directory, and the local SSH state used
        // to reach it are all keyed outside the workspace, so the
        // workspace-keyed claim set never covers them. Risk:
        // `TaskLaunchResourceResolver.appendRemoteWorkspaceGrants` hands every
        // remote-workspace run read-write `~/.ssh/known_hosts*` plus write on
        // `~/.ssh` (and, for a gcloud/IAP ProxyCommand, read-write on the
        // gcloud config directory), and concurrent runs race there and on the
        // shared remote directory (see
        // `remoteWorkspaceSSHGrantsAreProcessGlobalWithoutARemoteDirectoryClaim`).
        .remoteDirectory,
        // Provider auth/session state lives under one home directory per
        // runtime, not per task: `AgentRuntimeHomeStateAccess` puts `~/.claude`,
        // `~/.codex`, and friends on the sandbox write allow-list for every run
        // of that runtime. Risk: concurrent runs of one runtime rewrite the
        // same session/credential files (re-auth, config churn) with nothing
        // serializing them (see
        // `providerAccountStateIsWritableForEveryRunWithoutAnAccountSessionClaim`).
        .accountSession
    ]

    // MARK: - The ratchet

    @Test("Every declared resource kind is either claimed or consciously allowlisted")
    func everyDeclaredResourceKindIsClaimedOrAllowlisted() throws {
        let declared = Set(TaskExecutionResourceKind.allCases)
        let emitted = try emittedClaimKinds()

        #expect(
            emitted.union(Self.knownUnclaimedKinds) == declared,
            """
            Every TaskExecutionResourceKind must be emitted by \
            TaskExecutionResourceClaimResolver or listed in knownUnclaimedKinds \
            with a reason. Declared: \(describe(declared)). Emitted: \(describe(emitted)). \
            Allowlisted: \(describe(Self.knownUnclaimedKinds)).
            """
        )
        #expect(
            emitted.isDisjoint(with: Self.knownUnclaimedKinds),
            """
            These kinds are now emitted but still listed as unclaimed — remove \
            them from knownUnclaimedKinds and delete the matching documenting \
            test: \(describe(emitted.intersection(Self.knownUnclaimedKinds))).
            """
        )
    }

    @Test("Production only constructs claim kinds the scenario matrix reaches")
    func productionClaimConstructionsAreCoveredByScenarios() throws {
        let constructed = try claimKindsConstructedInProductionSources()
        let emitted = try emittedClaimKinds()

        #expect(
            constructed == emitted,
            """
            Every claim kind constructed in Astra/ must be reachable from the \
            scenario matrix in this file, otherwise a kind can be "emitted" in \
            code yet never exercised — the exact shape of the \
            declared-but-never-emitted bug this suite exists to catch. \
            Constructed in production: \(describe(constructed)). \
            Emitted by scenarios: \(describe(emitted)).
            """
        )
    }

    // MARK: - Behavioral coverage for the kinds that are claimed

    @Test("Ordinary work claims its writable workspace roots")
    func workspaceClaimsCoverEveryWritableRoot() throws {
        let workspace = Workspace(
            name: "Coverage",
            primaryPath: "/tmp/astra-claim-coverage-primary",
            additionalPaths: ["/tmp/astra-claim-coverage-extra"]
        )
        let reader = AgentTask(
            title: "Research the queue",
            goal: "Explain how the queue works.",
            workspace: workspace
        )
        reader.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        let writer = AgentTask(
            title: "Fix the queue",
            goal: "Update the queue implementation.",
            workspace: workspace
        )

        let readerClaims = TaskExecutionResourceClaimResolver.claims(for: reader)
        let writerClaims = TaskExecutionResourceClaimResolver.claims(for: writer)

        #expect(readerClaims.allSatisfy { $0.kind == .workspace })
        #expect(readerClaims.map(\.key) == [
            "/tmp/astra-claim-coverage-primary",
            "/tmp/astra-claim-coverage-extra"
        ])
        #expect(readerClaims.allSatisfy { $0.access == .shared })
        #expect(writerClaims.allSatisfy { $0.kind == .workspace && $0.access == .exclusive })
    }

    @Test("Network Git work claims the shared Git common directory")
    func networkGitWorkClaimsTheGitCommonDirectory() throws {
        let root = try makeTempDirectory("claim-coverage-network-git")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeWorktreeLayout(in: root, worktrees: ["wt-a", "wt-b"])

        let workspace = Workspace(name: "Worktrees", primaryPath: repository.root.path)
        let pushing = AgentTask(
            title: "Ship feature A",
            goal: "Update the parser, then git push the result.",
            workspace: workspace
        )
        let local = AgentTask(
            title: "Ship feature B",
            goal: "Update the renderer.",
            workspace: workspace
        )
        pushing.executionRootPath = repository.worktrees["wt-a"]?.path
        local.executionRootPath = repository.worktrees["wt-b"]?.path

        let pushingClaims = TaskExecutionResourceClaimResolver.claims(for: pushing)
        let localClaims = TaskExecutionResourceClaimResolver.claims(for: local)
        let gitClaim = try #require(pushingClaims.first { $0.kind == .gitCommonDirectory })

        #expect(gitClaim.key == repository.commonDirectory.standardizedFileURL.path)
        // The claim exists only where the grant does: a worktree writer with no
        // Git intent receives no external Git metadata grant, so claiming it
        // would serialize sibling worktrees for nothing.
        #expect(!localClaims.contains { $0.kind == .gitCommonDirectory })
    }

    @Test("Local Git inspection also claims the Git common directory")
    func localGitInspectionClaimsTheGitCommonDirectory() throws {
        let root = try makeTempDirectory("claim-coverage-local-git")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeWorktreeLayout(in: root, worktrees: ["wt-a"])

        // `GitCredentialContextResolver.runtimeSandboxContext` returns a
        // writable external Git path for local inspection too, so the claim has
        // to follow the local-inspection branch, not just the network branch.
        let task = AgentTask(
            title: "Inspect the worktree",
            goal: "Run git status to check the local diff.",
            workspace: Workspace(name: "Worktree", primaryPath: repository.worktrees["wt-a"]?.path ?? "")
        )

        let claims = TaskExecutionResourceClaimResolver.claims(for: task)
        let gitClaim = try #require(claims.first { $0.kind == .gitCommonDirectory })

        #expect(gitClaim.key == repository.commonDirectory.standardizedFileURL.path)
    }

    // MARK: - Documenting the uncovered grants

    @Test("Remote-workspace SSH grants are process-global but produce no remote-directory claim")
    func remoteWorkspaceSSHGrantsAreProcessGlobalWithoutARemoteDirectoryClaim() throws {
        let fileManager = FileManager.default
        let root = try makeTempDirectory("claim-coverage-remote-ssh")
        defer { try? fileManager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        let firstWorkspaceRoot = root.appendingPathComponent("workspace-a", isDirectory: true)
        let secondWorkspaceRoot = root.appendingPathComponent("workspace-b", isDirectory: true)
        try fileManager.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: firstWorkspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondWorkspaceRoot, withIntermediateDirectories: true)

        let sshConfig = sshDirectory.appendingPathComponent("config")
        let identityFile = sshDirectory.appendingPathComponent("id_release")
        let knownHosts = sshDirectory.appendingPathComponent("known_hosts")
        try """
        Host release-box
          HostName release.example.com
          User deploy
        """.write(to: sshConfig, atomically: true, encoding: .utf8)
        try "private-key-placeholder".write(to: identityFile, atomically: true, encoding: .utf8)
        try "release-box ssh-ed25519 AAAA\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        let connection = SSHConnection(
            name: "release-box",
            host: "release.example.com",
            user: "deploy",
            remotePath: "~/service",
            keyPath: "~/.ssh/id_release",
            configAlias: "release-box"
        )
        SSHConnectionManager.save([connection], workspacePath: firstWorkspaceRoot.path)
        SSHConnectionManager.save([connection], workspacePath: secondWorkspaceRoot.path)

        let first = AgentTask(
            title: "Update the release script",
            goal: "Update the deployment script on the remote host.",
            workspace: Workspace(name: "Release A", primaryPath: firstWorkspaceRoot.path)
        )
        let second = AgentTask(
            title: "Update the rollback script",
            goal: "Update the rollback script on the remote host.",
            workspace: Workspace(name: "Release B", primaryPath: secondWorkspaceRoot.path)
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: first,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "run",
            prompt: first.goal,
            contextText: "",
            workspacePath: firstWorkspaceRoot.path,
            homeDirectoryPath: home.path,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        // The launch plan hands this run write access to shared, home-scoped
        // SSH state — OpenSSH rewrites known-host files through temporary files
        // in the parent directory, so `~/.ssh` itself is writable.
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace
                && $0.access == .readWrite
                && $0.path == knownHosts.standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace
                && $0.access == .write
                && $0.path == sshDirectory.standardizedFileURL.path
        })

        let firstClaims = TaskExecutionResourceClaimResolver.claims(for: first)
        let secondClaims = TaskExecutionResourceClaimResolver.claims(for: second)

        // …and admission sees none of it. Both runs claim only their own
        // workspace root, so nothing keeps them from holding write access to
        // one `~/.ssh` — and to one remote working directory — at the same
        // time. When `.remoteDirectory` claims land, these expectations must
        // flip; that is the point of pinning them.
        #expect(!firstClaims.contains { $0.kind == .remoteDirectory })
        #expect(firstClaims.allSatisfy { $0.kind == .workspace })
        #expect(secondClaims.allSatisfy { $0.kind == .workspace })
        #expect(!firstClaims.contains {
            $0.key == sshDirectory.standardizedFileURL.path
                || $0.key == knownHosts.standardizedFileURL.path
        })
        #expect(TaskExecutionResourceBroker.canAcquire(
            lease(for: secondClaims, taskID: second.id),
            active: lease(for: firstClaims, taskID: first.id)
        ))
    }

    @Test("Shared Docker environment mounts are granted read-write with no docker claim")
    func dockerEnvironmentMountsAreGrantedWritableWithoutADockerClaim() throws {
        let fileManager = FileManager.default
        let root = try makeTempDirectory("claim-coverage-docker")
        defer { try? fileManager.removeItem(at: root) }
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let sharedCache = root.appendingPathComponent("shared-build-cache", isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedCache, withIntermediateDirectories: true)

        // A mount declared on the execution environment, not on the workspace:
        // every task pinned to this environment gets it, and no workspace claim
        // covers the host path.
        let mount = ExecutionEnvironmentMount(
            hostPath: sharedCache.path,
            containerPath: "/shared-build-cache",
            access: .readWrite,
            role: .additionalPath
        )
        let environment = WorkspaceExecutionEnvironment(
            id: "image:astra-coverage",
            kind: .dockerImage,
            displayName: "Coverage image",
            image: "astra/coverage:latest",
            mounts: [mount]
        )
        let task = AgentTask(
            title: "Rebuild the artifacts",
            goal: "Update the build outputs.",
            workspace: Workspace(name: "Containerized", primaryPath: workspaceRoot.path)
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "run",
            prompt: task.goal,
            contextText: "",
            workspacePath: workspaceRoot.path,
            executionEnvironment: environment,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
        let claims = TaskExecutionResourceClaimResolver.claims(for: task)

        #expect(plan.containerMounts.contains {
            $0.hostPath == mount.hostPath && $0.access == ExecutionEnvironmentMountAccess.readWrite.rawValue
        })
        #expect(!claims.contains { $0.kind == .docker })
        #expect(!claims.contains { $0.key == mount.hostPath })
    }

    @Test("Provider account state is writable for every run without an account-session claim")
    func providerAccountStateIsWritableForEveryRunWithoutAnAccountSessionClaim() throws {
        // One home-relative state directory per runtime, shared by every task
        // that uses it; `ExecutionSandbox` puts these on the run's write
        // allow-list.
        #expect(AgentRuntimeHomeStateAccess.claudeCode.explicitHomeWritableRelativePaths.contains(".claude"))
        #expect(AgentRuntimeHomeStateAccess.codexCLI.explicitHomeWritableRelativePaths.contains(".codex"))

        let first = AgentTask(
            title: "Update the parser",
            goal: "Update the parser implementation.",
            workspace: Workspace(name: "Account A", primaryPath: "/tmp/astra-claim-coverage-account-a"),
            runtime: .claudeCode
        )
        let second = AgentTask(
            title: "Update the renderer",
            goal: "Update the renderer implementation.",
            workspace: Workspace(name: "Account B", primaryPath: "/tmp/astra-claim-coverage-account-b"),
            runtime: .claudeCode
        )

        let firstClaims = TaskExecutionResourceClaimResolver.claims(for: first)
        let secondClaims = TaskExecutionResourceClaimResolver.claims(for: second)

        // Nothing identifies the provider account, so two concurrent runs of
        // one runtime are admitted together while both may rewrite the same
        // `~/.claude` session state.
        #expect(!firstClaims.contains { $0.kind == .accountSession })
        #expect(!secondClaims.contains { $0.kind == .accountSession })
        #expect(TaskExecutionResourceBroker.canAcquire(
            lease(for: secondClaims, taskID: second.id),
            active: lease(for: firstClaims, taskID: first.id)
        ))
    }

    // MARK: - Scenario matrix

    /// Every claim kind the real resolver produces across the reachable task
    /// shapes ASTRA supports today. Scenarios that cannot currently emit a new
    /// kind are still listed: they are the trip-wire that makes a future
    /// `.remoteDirectory` / `.docker` / `.browserSession` claim show up here
    /// instead of silently satisfying nothing.
    private func emittedClaimKinds() throws -> Set<TaskExecutionResourceKind> {
        let fileManager = FileManager.default
        let root = try makeTempDirectory("claim-coverage-matrix")
        defer { try? fileManager.removeItem(at: root) }

        let repository = try makeWorktreeLayout(
            in: root.appendingPathComponent("repo", isDirectory: true),
            worktrees: ["wt-a"]
        )
        let remoteWorkspaceRoot = root.appendingPathComponent("remote-workspace", isDirectory: true)
        let containerWorkspaceRoot = root.appendingPathComponent("container-workspace", isDirectory: true)
        try fileManager.createDirectory(at: remoteWorkspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: containerWorkspaceRoot, withIntermediateDirectories: true)
        SSHConnectionManager.save([
            SSHConnection(
                name: "release-box",
                host: "release.example.com",
                user: "deploy",
                remotePath: "~/service",
                configAlias: "release-box"
            )
        ], workspacePath: remoteWorkspaceRoot.path)

        let informational = AgentTask(
            title: "Research the scheduler",
            goal: "Explain how admission works.",
            workspace: Workspace(name: "Research", primaryPath: root.appendingPathComponent("research").path)
        )
        let mutating = AgentTask(
            title: "Fix the scheduler",
            goal: "Update the admission implementation.",
            workspace: Workspace(name: "Code", primaryPath: root.appendingPathComponent("code").path)
        )
        let networkGit = AgentTask(
            title: "Ship the fix",
            goal: "Update the parser, then git push the result.",
            workspace: Workspace(name: "Worktrees", primaryPath: repository.root.path)
        )
        networkGit.executionRootPath = repository.worktrees["wt-a"]?.path
        let localGit = AgentTask(
            title: "Inspect the checkout",
            goal: "Run git status to check the local diff.",
            workspace: Workspace(name: "Checkout", primaryPath: repository.checkout.path)
        )
        let remote = AgentTask(
            title: "Update the release script",
            goal: "Update the deployment script on the remote host.",
            workspace: Workspace(name: "Remote", primaryPath: remoteWorkspaceRoot.path)
        )
        let containerized = AgentTask(
            title: "Rebuild the artifacts",
            goal: "Update the build outputs.",
            workspace: Workspace(name: "Containerized", primaryPath: containerWorkspaceRoot.path)
        )
        containerized.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(
            WorkspaceExecutionEnvironment(
                id: "image:astra-coverage",
                kind: .dockerImage,
                displayName: "Coverage image",
                image: "astra/coverage:latest"
            )
        )
        let browsing = AgentTask(
            title: "Check the dashboard",
            goal: "Open the browser and inspect the dashboard.",
            workspace: Workspace(name: "Browser", primaryPath: root.appendingPathComponent("browser").path)
        )

        let scenarios: [(task: AgentTask, acceptedTurn: String?)] = [
            (informational, nil),
            (mutating, nil),
            (informational, "Now fix the scheduler and update the tests."),
            (networkGit, nil),
            (localGit, nil),
            (remote, nil),
            (containerized, nil),
            (browsing, nil)
        ]

        var kinds: Set<TaskExecutionResourceKind> = []
        for scenario in scenarios {
            let claims = TaskExecutionResourceClaimResolver.claims(
                for: scenario.task,
                acceptedTurn: scenario.acceptedTurn
            )
            kinds.formUnion(claims.map(\.kind))
        }
        return kinds
    }

    /// Claim kinds constructed anywhere in the production sources.
    ///
    /// `TaskExecutionResourceClaim` lives in `ASTRAModels` (`Astra/Models`),
    /// which only `Astra/` targets depend on, so scanning `Astra/` is
    /// exhaustive. The pattern intentionally matches a literal case name only:
    /// `TaskExecutionResourceAdmissionPolicy` rebuilds an existing claim with
    /// `kind: workspace.kind`, which introduces no new kind.
    private func claimKindsConstructedInProductionSources() throws -> Set<TaskExecutionResourceKind> {
        let sourceRoot = try TestRepositoryRoot.resolve().appendingPathComponent("Astra", isDirectory: true)
        let regex = try NSRegularExpression(
            pattern: #"TaskExecutionResourceClaim\(\s*kind:\s*\.([A-Za-z][A-Za-z0-9]*)"#
        )
        let byCaseName = Dictionary(
            uniqueKeysWithValues: TaskExecutionResourceKind.allCases.map { (String(describing: $0), $0) }
        )
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))

        var kinds: Set<TaskExecutionResourceKind> = []
        var unknownCaseNames: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
                let caseName = String(text[nameRange])
                if let kind = byCaseName[caseName] {
                    kinds.insert(kind)
                } else {
                    unknownCaseNames.insert(caseName)
                }
            }
        }

        #expect(
            unknownCaseNames.isEmpty,
            "Production constructs claim kinds this scan cannot resolve: \(unknownCaseNames.sorted())"
        )
        #expect(!kinds.isEmpty, "Found no TaskExecutionResourceClaim constructions under \(sourceRoot.path)")
        return kinds
    }

    // MARK: - Helpers

    private func describe(_ kinds: Set<TaskExecutionResourceKind>) -> String {
        kinds.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private func lease(
        for claims: [TaskExecutionResourceClaim],
        taskID: UUID
    ) -> [TaskResourceLockClaim] {
        TaskExecutionResourceBroker.lockClaims(
            for: claims,
            taskID: taskID,
            requestID: nil,
            runMode: "test"
        )
    }

    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct WorktreeLayout {
        let root: URL
        let checkout: URL
        let commonDirectory: URL
        let worktrees: [String: URL]
    }

    /// Builds the on-disk shape `git worktree add` produces, without shelling
    /// out to git: a main checkout with a real `.git` directory plus linked
    /// worktrees whose `.git` file points at an admin directory whose
    /// `commondir` resolves back to that one `.git`.
    private func makeWorktreeLayout(in root: URL, worktrees names: [String]) throws -> WorktreeLayout {
        let fileManager = FileManager.default
        let checkout = root.appendingPathComponent("main", isDirectory: true)
        let commonDirectory = checkout.appendingPathComponent(".git", isDirectory: true)
        try fileManager.createDirectory(at: commonDirectory, withIntermediateDirectories: true)

        var linked: [String: URL] = [:]
        for name in names {
            let worktree = root.appendingPathComponent(name, isDirectory: true)
            let adminDirectory = commonDirectory
                .appendingPathComponent("worktrees", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: adminDirectory, withIntermediateDirectories: true)
            try "gitdir: \(adminDirectory.path)\n".write(
                to: worktree.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )
            try "../..\n".write(
                to: adminDirectory.appendingPathComponent("commondir"),
                atomically: true,
                encoding: .utf8
            )
            linked[name] = worktree
        }
        return WorktreeLayout(
            root: root,
            checkout: checkout,
            commonDirectory: commonDirectory,
            worktrees: linked
        )
    }
}
