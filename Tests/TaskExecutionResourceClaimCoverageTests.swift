import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Claim-coverage fitness for `TaskExecutionResourceKind`.
///
/// `TaskExecutionResourceKind` declares the resource identities ASTRA is
/// willing to serialize on, but declaring a kind does nothing on its own: a
/// kind only affects admission once a resolver or the execution owner
/// actually emits a claim for it. `.gitCommonDirectory` shipped declared but
/// never emitted, and a reviewer had to find that by reading the diff.
///
/// These tests make the *whole* pattern checkable instead of one instance at a
/// time. Every declared kind must be exactly one of
///   (a) emitted by the real resolver in a reachable scenario,
///   (b) named in `kindsIsolatedWithoutAClaim` with the decision that keeps
///       tasks apart without a claim, and the document and tests that record
///       it, or
///   (c) named in `knownUnclaimedKinds` with a written reason and the concrete
///       race it leaves open.
/// A newly added kind belongs to none of them, so it fails until someone makes
/// a conscious decision. A listed kind that starts being emitted also fails,
/// so neither list can rot into a lie.
@Suite("Task execution resource claim coverage")
@MainActor
struct TaskExecutionResourceClaimCoverageTests {
    /// Kinds ASTRA declares but does **not** claim today, each with the race
    /// that leaves open. These are tracked gaps, not approved designs, so the
    /// list is meant to stay empty: Docker mounts and remote folders are now
    /// claimed (`TaskExecutionEnvironmentClaimTests`), and the browser and
    /// account kinds moved to `kindsIsolatedWithoutAClaim` once their
    /// isolation was decided and covered.
    private static let knownUnclaimedKinds: Set<TaskExecutionResourceKind> = []

    /// A kind no claim serializes because something else already keeps tasks
    /// apart. This is an approved contract, not a gap: each entry says what
    /// the decision is and where it is written down and tested.
    struct IsolationContract {
        let decision: String
        /// Repository-relative path of the document that records it.
        let document: String
        /// Test suites or test functions in `Tests/` that pin it.
        let tests: [String]
    }

    private static let kindsIsolatedWithoutAClaim: [TaskExecutionResourceKind: IsolationContract] = [
        // #552. A browser bridge registration belongs to one session and is
        // looked up by the persistent task that owns it, so a second browser
        // task gets its own binding instead of taking the first one's. The one
        // singleton left, the Controlled Browser's Chromium profile, is
        // reserved by `ControlledBrowserProfileLease` at the moment it is
        // opened, not for the length of a turn. A turn-long claim here would
        // be the provider-wide lock #480 rules out.
        .browserSession: IsolationContract(
            decision: "Owner-scoped bridge registrations plus a profile lease taken when Chromium is opened.",
            document: "docs/qa/2026-10-26-browser-owner-isolation.md",
            tests: [
                "ShelfBrowserOwnershipTests",
                "ShelfBrowserLifetimeTests",
                "ControlledBrowserProfileLeaseTests",
                "browserBindingsAreOwnerScopedWithoutAProviderWideLock"
            ]
        ),
        // #480. ASTRA does not serialize a provider or an account. What ASTRA
        // itself writes to steer a launch is per launch or per task, never in
        // the provider's home; what the provider keeps there is the CLI's own
        // state, relied on to tolerate two of its processes as it does in two
        // terminals. The one piece ASTRA reserves, a native session ID, has
        // its own emitted kind (`.nativeSession`).
        .accountSession: IsolationContract(
            decision: "Run-scoped ASTRA configuration; provider-owned state left to each CLI; native sessions reserved.",
            document: "docs/qa/2026-11-22-provider-state-concurrency-contract.md",
            tests: [
                "providerAccountStateFollowsItsDocumentedContract",
                "TemplateHookInjectionPolicyTests",
                "ClaudeSettingsSharedWriteTests",
                "RuntimeNativeSessionOwnershipTests"
            ]
        )
    ]

    // MARK: - The ratchet

    @Test("Every declared resource kind is either claimed or consciously allowlisted")
    func everyDeclaredResourceKindIsClaimedOrAllowlisted() throws {
        let declared = Set(TaskExecutionResourceKind.allCases)
        let emitted = try emittedClaimKinds()

        let contracted = Set(Self.kindsIsolatedWithoutAClaim.keys)
        let listed = Self.knownUnclaimedKinds.union(contracted)

        #expect(
            emitted.union(listed) == declared,
            """
            Every TaskExecutionResourceKind must be emitted by \
            TaskExecutionResourceClaimResolver, recorded in kindsIsolatedWithoutAClaim, \
            or listed in knownUnclaimedKinds with a reason. Declared: \(describe(declared)). \
            Emitted: \(describe(emitted)). Contracted: \(describe(contracted)). \
            Unclaimed: \(describe(Self.knownUnclaimedKinds)).
            """
        )
        #expect(
            emitted.isDisjoint(with: listed),
            """
            These kinds are now emitted but still listed as not claimed — remove \
            them from the list they are in: \(describe(emitted.intersection(listed))).
            """
        )
        #expect(
            Self.knownUnclaimedKinds.isDisjoint(with: contracted),
            "A kind is either a tracked gap or an approved contract, not both."
        )
        #expect(
            Self.knownUnclaimedKinds.isEmpty,
            """
            A kind listed as a gap needs an owner and an issue. Claim it, or record \
            the contract that makes a claim unnecessary: \(describe(Self.knownUnclaimedKinds)).
            """
        )
    }

    @Test("Every isolation contract points at a document and tests that exist")
    func isolationContractsPointAtRealEvidence() throws {
        let repository = try TestRepositoryRoot.resolve()
        let tests = repository.appendingPathComponent("Tests", isDirectory: true)
        var testSources = ""
        for case let url as URL in try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" && !url.path.contains("/ArchitectureFitnessTests/") {
            testSources += try String(contentsOf: url, encoding: .utf8)
        }
        for (kind, contract) in Self.kindsIsolatedWithoutAClaim {
            #expect(!contract.decision.isEmpty)
            let document = repository.appendingPathComponent(contract.document)
            #expect(FileManager.default.fileExists(atPath: document.path), "\(kind.rawValue): \(contract.document)")
            #expect(!contract.tests.isEmpty, "\(kind.rawValue) names no tests")
            for name in contract.tests {
                #expect(
                    testSources.contains("struct \(name)") || testSources.contains("func \(name)("),
                    "\(kind.rawValue): no test named \(name)"
                )
            }
        }
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

    // MARK: - Contracts that stand in for a claim

    @Test("Browser bindings are owner-scoped and browser tasks take no provider-wide lock")
    func browserBindingsAreOwnerScopedWithoutAProviderWideLock() throws {
        let fixture = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let independent = AgentTask(
            title: "Check the dashboard",
            goal: "Open the browser and inspect the dashboard.",
            workspace: Workspace(name: "Browser C", primaryPath: "/tmp/astra-claim-coverage-browser-c")
        )
        if let workspace = independent.workspace { fixture.container.mainContext.insert(workspace) }
        fixture.container.mainContext.insert(independent)
        try fixture.container.mainContext.save()
        func publish(_ task: AgentTask, session: UUID, token: String) {
            fixture.registry.update(
                endpoint: "http://127.0.0.1:12345", currentURL: token, currentTitle: token,
                taskID: task.id, taskOwnerID: task.persistentModelID, sessionID: session,
                accessToken: token, isPresented: true, isEnabled: true
            )
        }
        func token(_ task: AgentTask) -> String? {
            fixture.registry.environmentVariables(for: task.id, ownerID: ShelfBrowserOwner(task).modelID)["ASTRA_BROWSER_TOKEN"]
        }

        // Three browser tasks hold three bindings at once: nothing is
        // process-wide. `a` and `b` even share a task UUID (an imported copy).
        let sessions = (a: UUID(), b: UUID(), c: UUID())
        publish(fixture.a, session: sessions.a, token: "token-a")
        publish(fixture.b, session: sessions.b, token: "token-b")
        publish(independent, session: sessions.c, token: "token-c")
        #expect(token(fixture.a) == "token-a")
        #expect(token(fixture.b) == "token-b")
        #expect(token(independent) == "token-c")

        // One task cannot take another's binding. Publishing again as B, or as
        // the independent task, moves neither A's endpoint nor its credential…
        publish(fixture.b, session: sessions.b, token: "token-b-rotated")
        publish(independent, session: sessions.c, token: "token-c-rotated")
        #expect(token(fixture.a) == "token-a")
        // …a lookup that names A's task but not its owner gets nothing…
        #expect(fixture.registry.environmentVariables(for: fixture.a.id).isEmpty)
        #expect(fixture.registry.environmentVariables(
            for: fixture.a.id, ownerID: independent.persistentModelID).isEmpty)
        // …and tearing down the others leaves A bound.
        fixture.registry.remove(sessionID: sessions.b)
        fixture.registry.remove(sessionID: sessions.c)
        #expect(token(fixture.a) == "token-a")
        #expect(token(fixture.b) == nil)

        // Admission agrees: browser tasks in separate folders claim only
        // their folders, on the same runtime or on different ones.
        let sameProvider = AgentTask(
            title: "Check the report", goal: "Open the browser and inspect the report.",
            workspace: Workspace(name: "Browser D", primaryPath: "/tmp/astra-claim-coverage-browser-d"),
            runtime: .claudeCode
        )
        let otherProvider = AgentTask(
            title: "Check the queue", goal: "Open the browser and inspect the queue.",
            workspace: Workspace(name: "Browser E", primaryPath: "/tmp/astra-claim-coverage-browser-e"),
            runtime: .codexCLI
        )
        let holder = lease(for: TaskExecutionResourceClaimResolver.claims(for: independent), taskID: independent.id)
        for task in [sameProvider, otherProvider] {
            let claims = TaskExecutionResourceClaimResolver.claims(for: task)
            #expect(claims.allSatisfy { $0.kind == .workspace })
            #expect(TaskExecutionResourceBroker.canAcquire(lease(for: claims, taskID: task.id), active: holder))
        }
    }

    @Test("Provider account state follows its documented contract instead of a claim")
    func providerAccountStateFollowsItsDocumentedContract() throws {
        // The state the contract is about: one home-relative folder per
        // runtime, writable to every run of that runtime.
        let providerState: [(runtime: AgentRuntimeID, access: AgentRuntimeHomeStateAccess, folder: String)] = [
            (.claudeCode, .claudeCode, ".claude"),
            (.copilotCLI, .copilotCLI, ".copilot"),
            (.codexCLI, .codexCLI, ".codex"),
            (.cursorCLI, .cursorCLI, ".cursor"),
            (.antigravityCLI, .antigravityCLI, ".gemini"),
            (.openCodeCLI, .openCodeCLI, ".local/share/opencode")
        ]
        let document = try String(contentsOf: TestRepositoryRoot.resolve().appendingPathComponent(
            try #require(Self.kindsIsolatedWithoutAClaim[.accountSession]).document), encoding: .utf8)

        for state in providerState {
            #expect(state.access.inheritedHomeWritableRelativePaths.contains(state.folder), "\(state.runtime.rawValue)")
            // Every built-in CLI has its row in the written contract.
            #expect(document.contains("`\(state.runtime.rawValue)`"), "\(state.runtime.rawValue) is not documented")
            #expect(document.contains(state.folder), "\(state.folder) is not documented")

            // The decision: two tasks on one runtime, in separate folders,
            // start together. Nothing serializes the provider or the account.
            let first = AgentTask(
                title: "Update the parser", goal: "Update the parser implementation.",
                workspace: Workspace(name: "Account A", primaryPath: "/tmp/astra-claim-coverage-account-a"),
                runtime: state.runtime
            )
            let second = AgentTask(
                title: "Update the renderer", goal: "Update the renderer implementation.",
                workspace: Workspace(name: "Account B", primaryPath: "/tmp/astra-claim-coverage-account-b"),
                runtime: state.runtime
            )
            let firstClaims = TaskExecutionResourceClaimResolver.claims(for: first)
            let secondClaims = TaskExecutionResourceClaimResolver.claims(for: second)
            #expect(!(firstClaims + secondClaims).contains { $0.kind == .accountSession })
            #expect(TaskExecutionResourceBroker.canAcquire(
                lease(for: secondClaims, taskID: second.id),
                active: lease(for: firstClaims, taskID: first.id)
            ), "\(state.runtime.rawValue)")
        }
        // The document states its own evidence limit rather than claiming a
        // provider's behaviour was verified.
        #expect(document.contains("not what was verified"))
    }

    // MARK: - Scenario matrix

    /// Every claim kind the real resolver produces across the reachable task
    /// shapes ASTRA supports today. Scenarios that cannot currently emit a new
    /// kind are still listed: they are the trip-wire that makes a future
    /// `.browserSession` claim show up here instead of silently satisfying
    /// nothing.
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
        let sharedCache = root.appendingPathComponent("shared-build-cache", isDirectory: true)
        try fileManager.createDirectory(at: remoteWorkspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: containerWorkspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedCache, withIntermediateDirectories: true)
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
                image: "astra/coverage:latest",
                // A mount declared on the environment, not on the workspace:
                // every task on this environment gets it.
                mounts: [ExecutionEnvironmentMount(
                    hostPath: sharedCache.path,
                    containerPath: "/shared-build-cache",
                    access: .readWrite,
                    role: .additionalPath
                )]
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
        // Native continuation is selected at launch, after the workspace
        // resolver. Exercise its real admission boundary, not a literal claim.
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .codexCLI, goal: "Synthetic", model: "default")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        try owner.prepareLaunch(sessionID: "coverage-session")
        kinds.formUnion(try RuntimeResourceOwnership.claims(in: RuntimeExecutionOwner.store(in: h.context), context: h.context).map(\.resourceKind))
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
