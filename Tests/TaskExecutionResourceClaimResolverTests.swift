import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task execution resource claim resolver")
struct TaskExecutionResourceClaimResolverTests {
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
}
