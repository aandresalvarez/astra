import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task execution resource claim resolver")
struct TaskExecutionResourceClaimResolverTests {
    @Test("Contrast after a negated read action remains a write request")
    func contrastAfterNegationIsExclusive() {
        let task = AgentTask(title: "Review", goal: "Don't just review—fix the bug")

        #expect(TaskExecutionResourceClaimResolver.workspaceAccess(for: task) == .exclusive)
    }

    @Test("Informational work in one workspace uses a shared claim")
    func informationalWorkUsesSharedClaim() throws {
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/astra-claim-research")
        let task = AgentTask(
            title: "Research release notes",
            goal: "Summarize the latest release notes and explain the differences.",
            workspace: workspace
        )

        let claim = try #require(TaskExecutionResourceClaimResolver.claims(for: task).first)

        #expect(claim.kind == .workspace)
        #expect(claim.key == "/tmp/astra-claim-research")
        #expect(claim.access == .shared)
    }

    @Test("Every writable workspace path receives a deterministic claim")
    func additionalWritablePathsAreClaimed() {
        let workspace = Workspace(
            name: "Multi-root",
            primaryPath: "/tmp/astra-claim-primary",
            additionalPaths: [
                "/tmp/astra-claim-shared/../astra-claim-shared",
                "/tmp/astra-claim-primary",
                "/tmp/astra-claim-secondary"
            ]
        )
        let task = AgentTask(
            title: "Update shared data",
            goal: "Write the requested changes.",
            workspace: workspace
        )

        let claims = TaskExecutionResourceClaimResolver.claims(for: task)

        #expect(claims.map(\.key) == [
            "/tmp/astra-claim-primary",
            "/tmp/astra-claim-shared",
            "/tmp/astra-claim-secondary"
        ])
        #expect(claims.allSatisfy { $0.kind == .workspace && $0.access == .exclusive })

        let otherWorkspace = Workspace(
            name: "Other multi-root",
            primaryPath: "/tmp/astra-claim-other",
            additionalPaths: ["/tmp/astra-claim-shared"]
        )
        let otherTask = AgentTask(
            title: "Update other shared data",
            goal: "Write the requested changes.",
            workspace: otherWorkspace
        )
        let otherClaims = TaskExecutionResourceClaimResolver.claims(for: otherTask)
        #expect(Set(claims.map(\.key)).intersection(otherClaims.map(\.key)) == Set([
            "/tmp/astra-claim-shared"
        ]))
    }

    @Test("Accepted follow-up intent can strengthen an informational task claim")
    func acceptedTurnStrengthensClaim() {
        let workspace = Workspace(name: "Follow-up", primaryPath: "/tmp/astra-claim-follow-up")
        let task = AgentTask(
            title: "Research the scheduler",
            goal: "Explain the current implementation.",
            workspace: workspace
        )

        #expect(TaskExecutionResourceClaimResolver.claims(
            for: task,
            acceptedTurn: "Summarize the remaining risks."
        ).first?.access == .shared)
        #expect(TaskExecutionResourceClaimResolver.claims(
            for: task,
            acceptedTurn: "Now fix the scheduler and update the tests."
        ).first?.access == .exclusive)
    }

    @Test("Negated mutation language keeps informational work shared")
    func negatedMutationLanguageDoesNotEscalateInformationalWork() {
        let workspace = Workspace(name: "Read Only Research", primaryPath: "/tmp/astra-claim-negation")
        let negatedGoals = [
            "Explain the current implementation. Do not create or modify workspace files.",
            "Inspect the scheduler without changing or writing workspace files.",
            "Research the queue, but don't edit files.",
            "Review the implementation; never apply a patch."
        ]
        let affirmative = AgentTask(
            title: "Research queue behavior and modify the implementation",
            goal: "Summarize the findings, then create the required workspace files.",
            workspace: workspace
        )
        let mixed = AgentTask(
            title: "Do not research; create the report",
            goal: "Write the findings to a workspace file.",
            workspace: workspace
        )

        for goal in negatedGoals {
            let negated = AgentTask(
                title: "Research and summarize queue behavior",
                goal: goal,
                workspace: workspace
            )
            #expect(TaskExecutionResourceClaimResolver.claims(for: negated).first?.access == .shared)
        }
        #expect(TaskExecutionResourceClaimResolver.claims(for: affirmative).first?.access == .exclusive)
        #expect(TaskExecutionResourceClaimResolver.claims(for: mixed).first?.access == .exclusive)
    }

    @Test("Mutation, test, and artifact work require exclusive claims")
    func workspaceChangingWorkUsesExclusiveClaims() {
        let workspace = Workspace(name: "Code", primaryPath: "/tmp/astra-claim-code")
        let mutation = AgentTask(
            title: "Implement the queue fix",
            goal: "Update the scheduler implementation.",
            workspace: workspace
        )
        let tests = AgentTask(
            title: "Verify scheduler behavior",
            goal: "Inspect the scheduler behavior.",
            workspace: workspace,
            validationStrategy: .runTests
        )
        let artifact = AgentTask(
            title: "Create a report file",
            goal: "Write the findings to a Markdown file.",
            workspace: workspace
        )
        let ambiguous = AgentTask(
            title: "Handle this task",
            goal: "Complete the requested work.",
            workspace: workspace
        )

        for task in [mutation, tests, artifact, ambiguous] {
            #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.access == .exclusive)
        }
    }

    @Test("Explicit access declarations override inferred intent")
    func explicitAccessMarkersOverrideInference() {
        let workspace = Workspace(name: "Markers", primaryPath: "/tmp/astra-claim-markers")
        let declaredReader = AgentTask(
            title: "Implement a fix",
            goal: "Change the implementation.",
            workspace: workspace
        )
        declaredReader.constraints = ["astra-resource-access: read-only"]

        let declaredWriter = AgentTask(
            title: "Research behavior",
            goal: "Summarize the current implementation.",
            workspace: workspace
        )
        declaredWriter.inputs = ["resource_access=write"]

        #expect(TaskExecutionResourceClaimResolver.claims(for: declaredReader).first?.access == .shared)
        #expect(TaskExecutionResourceClaimResolver.claims(for: declaredWriter).first?.access == .exclusive)
    }

    @Test("Pinned execution roots produce distinct workspace claim keys")
    func executionRootSeparatesClaimKeys() throws {
        let workspace = Workspace(name: "Worktrees", primaryPath: "/tmp/astra-claim-worktrees")
        let first = AgentTask(title: "Research first", goal: "Summarize status.", workspace: workspace)
        let second = AgentTask(title: "Research second", goal: "Summarize status.", workspace: workspace)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-claim-roots-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = root.appendingPathComponent("feature-a", isDirectory: true)
        let secondRoot = root.appendingPathComponent("feature-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        first.executionRootPath = firstRoot.path + "/../feature-a"
        second.executionRootPath = secondRoot.path

        let firstClaim = try #require(TaskExecutionResourceClaimResolver.claims(for: first).first)
        let secondClaim = try #require(TaskExecutionResourceClaimResolver.claims(for: second).first)

        #expect(firstClaim.key == firstRoot.standardizedFileURL.path)
        #expect(secondClaim.key == secondRoot.standardizedFileURL.path)
        #expect(firstClaim.key != secondClaim.key)
        #expect(firstClaim.access == .shared)
        #expect(secondClaim.access == .shared)
    }

    @Test("Template-hook injection claims the settings-owning workspace exclusively")
    func templateHookInjectionRequiresExclusiveWorkspaceClaim() throws {
        let workspace = Workspace(name: "Hooks", primaryPath: "/tmp/astra-claim-hooks")
        let task = AgentTask(
            title: "Research release notes",
            goal: "Summarize the latest release notes and explain the differences.",
            workspace: workspace
        )

        // Informational language alone stays shared…
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.access == .shared)
        // …and an empty hook payload never touches the settings file.
        task.templateHooksJSON = "{}"
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.access == .shared)

        // But ASTRA rewrites `.claude/settings.local.json` for real hooks, so
        // two of these must never run concurrently in one workspace.
        task.templateHooksJSON = #"{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}"#
        let claims = TaskExecutionResourceClaimResolver.claims(for: task)
        #expect(claims.allSatisfy { $0.access == .exclusive })
        #expect(claims.contains { $0.kind == .workspace && $0.key == "/tmp/astra-claim-hooks" })
    }

    @Test("A pinned execution root still claims the hook-injected workspace root")
    func templateHookInjectionClaimsWorkspaceRootFromPinnedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-claim-hook-roots-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let firstRoot = workspaceRoot.appendingPathComponent("feature-a", isDirectory: true)
        let secondRoot = workspaceRoot.appendingPathComponent("feature-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Hooked worktrees", primaryPath: workspaceRoot.path)
        let hooks = #"{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}"#
        let first = AgentTask(title: "Research first", goal: "Summarize status.", workspace: workspace)
        let second = AgentTask(title: "Research second", goal: "Summarize status.", workspace: workspace)
        first.executionRootPath = firstRoot.path
        second.executionRootPath = secondRoot.path
        first.templateHooksJSON = hooks
        second.templateHooksJSON = hooks

        let firstClaims = TaskExecutionResourceClaimResolver.claims(for: first)
        let secondClaims = TaskExecutionResourceClaimResolver.claims(for: second)

        // The pinned roots stay first (and distinct), but hook injection targets
        // the workspace root, so both tasks must claim it exclusively.
        #expect(firstClaims.first?.key == firstRoot.standardizedFileURL.path)
        #expect(secondClaims.first?.key == secondRoot.standardizedFileURL.path)
        for claims in [firstClaims, secondClaims] {
            #expect(claims.contains {
                $0.kind == .workspace
                    && $0.key == workspaceRoot.standardizedFileURL.path
                    && $0.access == .exclusive
            })
        }
        #expect(!TaskExecutionResourceBroker.canAcquire(
            lease(for: secondClaims, taskID: second.id),
            active: lease(for: firstClaims, taskID: first.id)
        ))
    }

    @Test("Sibling linked worktrees conflict on their shared Git common directory")
    func linkedWorktreesShareAGitCommonDirectoryClaim() throws {
        let repository = try makeWorktreeLayout(worktrees: ["wt-a", "wt-b"])
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let otherRepository = try makeWorktreeLayout(worktrees: ["wt-a"])
        defer { try? FileManager.default.removeItem(at: otherRepository.root) }

        let workspace = Workspace(name: "Worktrees", primaryPath: repository.root.path)
        let first = AgentTask(title: "Ship feature A", goal: "Update the parser.", workspace: workspace)
        let second = AgentTask(title: "Ship feature B", goal: "Update the renderer.", workspace: workspace)
        let unrelated = AgentTask(
            title: "Ship other repository",
            goal: "Update the other project.",
            workspace: Workspace(name: "Other", primaryPath: otherRepository.root.path)
        )
        first.executionRootPath = repository.worktrees["wt-a"]?.path
        second.executionRootPath = repository.worktrees["wt-b"]?.path
        unrelated.executionRootPath = otherRepository.worktrees["wt-a"]?.path

        let firstClaims = TaskExecutionResourceClaimResolver.claims(for: first)
        let secondClaims = TaskExecutionResourceClaimResolver.claims(for: second)
        let unrelatedClaims = TaskExecutionResourceClaimResolver.claims(for: unrelated)
        let firstGit = try #require(firstClaims.first { $0.kind == .gitCommonDirectory })
        let secondGit = try #require(secondClaims.first { $0.kind == .gitCommonDirectory })
        let unrelatedGit = try #require(unrelatedClaims.first { $0.kind == .gitCommonDirectory })

        #expect(firstGit.key == repository.commonDirectory.standardizedFileURL.path)
        #expect(firstGit.key == secondGit.key)
        #expect(firstGit.access == .exclusive)
        #expect(unrelatedGit.key != firstGit.key)

        // The worktree roots themselves never overlapped — only the shared Git
        // metadata makes these two runs conflict.
        #expect(Set(firstClaims.filter { $0.kind == .workspace }.map(\.key))
            .isDisjoint(with: secondClaims.filter { $0.kind == .workspace }.map(\.key)))
        #expect(!TaskExecutionResourceBroker.canAcquire(
            lease(for: secondClaims, taskID: second.id),
            active: lease(for: firstClaims, taskID: first.id)
        ))
        #expect(TaskExecutionResourceBroker.canAcquire(
            lease(for: unrelatedClaims, taskID: unrelated.id),
            active: lease(for: firstClaims, taskID: first.id)
        ))
    }

    @Test("A main checkout claims the same common directory as its worktrees")
    func mainCheckoutSharesTheWorktreeCommonDirectoryClaim() throws {
        let repository = try makeWorktreeLayout(worktrees: ["wt-a"])
        defer { try? FileManager.default.removeItem(at: repository.root) }

        let mainTask = AgentTask(
            title: "Ship from the main checkout",
            goal: "Update the parser.",
            workspace: Workspace(name: "Main", primaryPath: repository.checkout.path)
        )
        let worktreeTask = AgentTask(
            title: "Ship from a worktree",
            goal: "Update the renderer.",
            workspace: Workspace(name: "Worktree", primaryPath: repository.worktrees["wt-a"]?.path ?? "")
        )

        let mainClaims = TaskExecutionResourceClaimResolver.claims(for: mainTask)
        let worktreeClaims = TaskExecutionResourceClaimResolver.claims(for: worktreeTask)
        let mainGit = try #require(mainClaims.first { $0.kind == .gitCommonDirectory })

        #expect(mainGit.key == repository.commonDirectory.standardizedFileURL.path)
        #expect(worktreeClaims.contains { $0.kind == .gitCommonDirectory && $0.key == mainGit.key })
        #expect(!TaskExecutionResourceBroker.canAcquire(
            lease(for: worktreeClaims, taskID: worktreeTask.id),
            active: lease(for: mainClaims, taskID: mainTask.id)
        ))
    }

    @Test("Admission consumes the immutable persisted claim after task edits")
    func persistedClaimRemainsImmutableAfterTaskChanges() throws {
        let workspace = Workspace(name: "Immutable", primaryPath: "/tmp/astra-claim-original")
        let task = AgentTask(
            title: "Research the implementation",
            goal: "Summarize how it works.",
            workspace: workspace
        )
        let submittedClaim = try #require(TaskExecutionResourceClaimResolver.claims(for: task).first)
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [submittedClaim]
        )

        task.title = "Implement the change"
        task.goal = "Modify the implementation."
        let mutatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-claim-mutated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mutatedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mutatedRoot) }
        task.executionRootPath = mutatedRoot.path

        let admissionClaim = try #require(
            TaskExecutionResourceClaimResolver.workspaceClaim(for: request, task: task)
        )

        #expect(admissionClaim == submittedClaim)
        #expect(admissionClaim.access == .shared)
        #expect(admissionClaim.key == "/tmp/astra-claim-original")
        #expect(TaskExecutionResourceClaimResolver.workspaceAccess(for: request) == .shared)
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: request,
            task: task
        ))

        let legacyClaim = try #require(
            TaskExecutionResourceClaimResolver.workspaceClaim(for: nil, task: task)
        )
        #expect(legacyClaim.access == .exclusive)
        #expect(legacyClaim.key == mutatedRoot.standardizedFileURL.path)
    }

    @Test("Malformed and empty durable claims fail closed to an exclusive workspace")
    func malformedClaimsFailClosed() throws {
        let workspace = Workspace(name: "Fail Closed", primaryPath: "/tmp/astra-claim-fail-closed")
        let task = AgentTask(
            title: "Research current state",
            goal: "Summarize current state.",
            workspace: workspace
        )
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: []
        )

        for invalidJSON in ["[]", "{broken", "[{\"kind\":\"future_kind\"}]"] {
            request.resourceClaimsJSON = invalidJSON
            let claims = TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task)
            let fallback = try #require(claims.first)
            #expect(claims.count == 1)
            #expect(fallback.kind == .workspace)
            #expect(fallback.key == "/tmp/astra-claim-fail-closed")
            #expect(fallback.access == .exclusive)
        }

        request.resourceClaimsJSON = """
        [{"kind":"account_session","key":"provider:account","access":"shared"}]
        """
        let typedClaims = TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task)
        #expect(typedClaims.count == 2)
        #expect(typedClaims.contains { $0.kind == .accountSession && $0.access == .shared })
        #expect(typedClaims.contains { $0.kind == .workspace && $0.access == .exclusive })
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
    private func makeWorktreeLayout(worktrees names: [String]) throws -> WorktreeLayout {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("astra-claim-worktree-\(UUID().uuidString)", isDirectory: true)
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
