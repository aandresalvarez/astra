import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Global execution resource broker")
struct GlobalResourceBrokerTests {
    @Test("Compatibility is global across workspaces and keyed by resource kind")
    @MainActor
    func globalCompatibilityUsesTypedIdentity() throws {
        let firstWorkspace = Workspace(name: "First", primaryPath: "/tmp/astra-global-first")
        let secondWorkspace = Workspace(name: "Second", primaryPath: "/tmp/astra-global-second")
        let holder = AgentTask(title: "Holder", goal: "Use account", workspace: firstWorkspace)
        let candidate = AgentTask(title: "Candidate", goal: "Use account", workspace: secondWorkspace)
        let queue = TaskQueue(poolSize: 1)
        let sharedID = "provider:tenant:account"

        let held = try #require(queue.acquireResourceLocksIfAvailable(
            TaskExecutionResourceBroker.lockClaims(
                for: [TaskExecutionResourceClaim(
                    kind: .accountSession,
                    key: sharedID,
                    access: .exclusive
                )],
                taskID: holder.id,
                requestID: UUID(),
                runMode: "test"
            ),
            task: holder
        ))
        defer { queue.releaseResourceLocks(held, task: holder) }

        let sameAccount = TaskExecutionResourceBroker.lockClaims(
            for: [TaskExecutionResourceClaim(
                kind: .accountSession,
                key: sharedID,
                access: .exclusive
            )],
            taskID: candidate.id,
            requestID: UUID(),
            runMode: "test"
        )
        let sameTextDifferentKind = TaskExecutionResourceBroker.lockClaims(
            for: [TaskExecutionResourceClaim(
                kind: .browserSession,
                key: sharedID,
                access: .exclusive
            )],
            taskID: candidate.id,
            requestID: UUID(),
            runMode: "test"
        )

        #expect(!queue.canAcquireResourceLocks(sameAccount))
        #expect(queue.canAcquireResourceLocks(sameTextDifferentKind))
    }

    @Test("Shared claims coexist while either exclusive side conflicts")
    func sharedAndExclusiveMatrix() {
        let taskA = UUID()
        let taskB = UUID()
        let sharedA = claim(taskID: taskA, access: .readOnly)
        let sharedB = claim(taskID: taskB, access: .readOnly)
        let writerA = claim(taskID: taskA, access: .write)
        let writerB = claim(taskID: taskB, access: .write)

        #expect(!TaskExecutionResourceBroker.conflicts(sharedA, sharedB))
        #expect(TaskExecutionResourceBroker.conflicts(sharedA, writerB))
        #expect(TaskExecutionResourceBroker.conflicts(writerA, sharedB))
        #expect(TaskExecutionResourceBroker.conflicts(writerA, writerB))

        let normalized = TaskExecutionResourceBroker.lockClaims(
            for: [
                TaskExecutionResourceClaim(kind: .accountSession, key: " shared ", access: .shared),
                TaskExecutionResourceClaim(kind: .accountSession, key: "shared", access: .exclusive)
            ],
            taskID: taskA,
            requestID: UUID(),
            runMode: "test"
        )
        #expect(normalized.count == 1)
        #expect(normalized.first?.accessMode == .write)
    }

    @Test("A multi-resource lease acquires atomically in deterministic order")
    @MainActor
    func multiResourceLeaseIsAtomic() throws {
        let workspace = Workspace(name: "Atomic", primaryPath: "/tmp/astra-global-atomic")
        let holder = AgentTask(title: "Holder", goal: "Hold B", workspace: workspace)
        let candidate = AgentTask(title: "Candidate", goal: "Use A and B", workspace: workspace)
        let queue = TaskQueue(poolSize: 1)
        let heldClaims = TaskExecutionResourceBroker.lockClaims(
            for: [TaskExecutionResourceClaim(kind: .docker, key: "b", access: .exclusive)],
            taskID: holder.id,
            requestID: UUID(),
            runMode: "test"
        )
        let held = try #require(queue.acquireResourceLocksIfAvailable(heldClaims, task: holder))

        let requested = TaskExecutionResourceBroker.lockClaims(
            for: [
                TaskExecutionResourceClaim(kind: .docker, key: "b", access: .exclusive),
                TaskExecutionResourceClaim(kind: .accountSession, key: "a", access: .shared)
            ],
            taskID: candidate.id,
            requestID: UUID(),
            runMode: "test"
        )
        #expect(requested.map(\.resourceKind) == [.accountSession, .docker])
        #expect(queue.acquireResourceLocksIfAvailable(requested, task: candidate) == nil)
        #expect(queue.activeResourceLocks == held)

        queue.releaseResourceLocks(held, task: holder)
        let acquired = try #require(queue.acquireResourceLocksIfAvailable(requested, task: candidate))
        #expect(acquired == requested)
        #expect(queue.activeResourceLocks == requested)
        queue.releaseResourceLocks(acquired, task: candidate)
    }

    @Test("Filesystem claims conflict across workspace records by canonical ancestor")
    func filesystemClaimsUseCanonicalHierarchy() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-global-path-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("reports/output.md")
        let parent = claim(taskID: UUID(), kind: .workspace, key: root.path, access: .readOnly)
        let writer = claim(taskID: UUID(), kind: .workspace, key: child.path, access: .write)
        let sibling = claim(
            taskID: UUID(),
            kind: .workspace,
            key: root.deletingLastPathComponent().appendingPathComponent("sibling/output.md").path,
            access: .write
        )

        #expect(TaskExecutionResourceBroker.conflicts(parent, writer))
        #expect(!TaskExecutionResourceBroker.conflicts(parent, sibling))
    }

    @Test("Resource lock event payload keeps v1 compatibility and carries typed v2 identity")
    func resourceLockPayloadCompatibility() throws {
        let v1 = """
        {"v":1,"resourceKey":"legacy","accessMode":"write","runMode":"task","status":"acquired"}
        """
        let legacy = try JSONDecoder().decode(TaskResourceLockPayload.self, from: Data(v1.utf8))
        #expect(legacy.version == 1)
        #expect(legacy.resourceKind == nil)
        #expect(legacy.requestID == nil)

        let requestID = UUID()
        let v2 = TaskResourceLockPayload(
            version: 2,
            resourceKey: "provider:account",
            accessMode: .write,
            runMode: "request",
            status: "waiting",
            resourceKind: .accountSession,
            requestID: requestID
        )
        let roundTrip = try JSONDecoder().decode(
            TaskResourceLockPayload.self,
            from: JSONEncoder().encode(v2)
        )
        #expect(roundTrip == v2)
    }

    private func claim(
        taskID: UUID,
        kind: TaskExecutionResourceKind = .accountSession,
        key: String = "shared",
        access: TaskResourceAccessMode
    ) -> TaskResourceLockClaim {
        TaskResourceLockClaim(
            taskID: taskID,
            resourceKey: key,
            accessMode: access,
            runMode: "test",
            resourceKind: kind
        )
    }
}
