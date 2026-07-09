import Testing
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

// MARK: - Helper

private func makeTask(
    title: String = "Test Task",
    goal: String = "Do something",
    isolation: IsolationStrategy = .sameDirectory
) -> AgentTask {
    let task = AgentTask(title: title, goal: goal)
    task.isolationStrategy = isolation
    return task
}

private func makeQueueLockContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

// MARK: - TaskQueue Parallel Execution

@Suite("TaskQueue Parallel Execution")
@MainActor
struct QueueLockTests {

    @Test("activeTasks starts empty")
    func startsEmpty() {
        let queue = TaskQueue(poolSize: 2)
        #expect(queue.activeTasks.isEmpty)
    }

    @Test("cancelAll clears active tasks")
    @MainActor
    func cancelAllClearsActive() {
        let queue = TaskQueue(poolSize: 2)
        queue.activeTasks.insert(UUID())
        queue.activeTasks.insert(UUID())
        #expect(queue.activeTasks.count == 2)

        queue.cancelAll()
        #expect(queue.activeTasks.isEmpty)
    }

    @Test("Pool size initializes correct number of workers")
    func poolSize() {
        let queue1 = TaskQueue(poolSize: 1)
        #expect(queue1.workers.count == 1)

        let queue3 = TaskQueue(poolSize: 3)
        #expect(queue3.workers.count == 3)

        let queue5 = TaskQueue(poolSize: 5)
        #expect(queue5.workers.count == 5)
    }

    @Test("hasAvailableWorker is true when no tasks running")
    func availableWorker() {
        let queue = TaskQueue(poolSize: 2)
        #expect(queue.hasAvailableWorker)
    }

    @Test("activeCount is zero initially")
    func activeCountZero() {
        let queue = TaskQueue(poolSize: 3)
        #expect(queue.activeCount == 0)
    }

    @Test("resizePool grows pool with idle workers")
    func resizePoolGrow() {
        let queue = TaskQueue(poolSize: 2)
        #expect(queue.workers.count == 2)

        queue.resizePool(to: 5)
        #expect(queue.workers.count == 5)
        #expect(queue.hasAvailableWorker)
    }

    @Test("resizePool shrinks by removing idle workers")
    func resizePoolShrink() {
        let queue = TaskQueue(poolSize: 4)
        #expect(queue.workers.count == 4)

        queue.resizePool(to: 2)
        #expect(queue.workers.count == 2)
    }

    @Test("resizePool does not go below 1")
    func resizePoolMinimum() {
        let queue = TaskQueue(poolSize: 3)
        queue.resizePool(to: 0) // should be ignored
        #expect(queue.workers.count == 3)
    }

    @Test("resizePool no-ops when size unchanged")
    func resizePoolSameSize() {
        let queue = TaskQueue(poolSize: 3)
        queue.resizePool(to: 3)
        #expect(queue.workers.count == 3)
    }

    @Test("applySettings propagates to all workers including new ones")
    func applySettingsAfterResize() {
        let queue = TaskQueue(poolSize: 2)
        queue.applySettings(claudePath: "/custom/claude", timeoutSeconds: 300, validationModel: "haiku", skipPermissions: false)

        // Verify existing workers got settings
        for worker in queue.workers {
            #expect(worker.claudePath == "/custom/claude")
            #expect(worker.timeoutSeconds == 300)
            #expect(worker.skipPermissions == false)
        }

        // Resize and apply again
        queue.resizePool(to: 4)
        queue.applySettings(claudePath: "/custom/claude", timeoutSeconds: 300, validationModel: "haiku", skipPermissions: false)

        // New workers should also have settings
        #expect(queue.workers.count == 4)
        for worker in queue.workers {
            #expect(worker.claudePath == "/custom/claude")
        }
    }

    @Test("applySettings defaults to restricted permissions")
    func applySettingsDefaultsRestricted() {
        let queue = TaskQueue(poolSize: 2)
        queue.applySettings(claudePath: "/custom/claude", timeoutSeconds: 300, validationModel: "haiku")

        for worker in queue.workers {
            #expect(worker.skipPermissions == false)
            #expect(worker.permissionPolicy == .restricted)
        }
    }

    @Test("applySettings propagates provider-keyed runtime settings")
    func applySettingsPropagatesProviderKeyedRuntimeSettings() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/opt/future/bin/future", for: futureRuntime)
        settings.setHomeDirectory("/tmp/future-home", for: futureRuntime)

        let queue = TaskQueue(poolSize: 2)
        queue.applySettings(
            claudePath: nil,
            providerSettings: settings,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 300,
            validationModel: "haiku"
        )

        for worker in queue.workers {
            #expect(worker.executablePath(for: futureRuntime) == "/opt/future/bin/future")
            #expect(worker.homeDirectory(for: futureRuntime) == "/tmp/future-home")
        }
    }

    @Test("applySettings keeps Copilot channel home when provider settings omit it")
    func applySettingsKeepsCopilotChannelHomeWhenProviderSettingsOmitIt() {
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/opt/copilot/bin/copilot", for: .copilotCLI)

        let queue = TaskQueue(poolSize: 2)
        queue.applySettings(
            claudePath: nil,
            providerSettings: settings,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 300,
            validationModel: "haiku"
        )

        for worker in queue.workers {
            #expect(worker.executablePath(for: .copilotCLI) == "/opt/copilot/bin/copilot")
            #expect(worker.homeDirectory(for: .copilotCLI) == CopilotCLIRuntime.channelHome())
        }
    }

    @Test("applySettings merges explicit built-in paths into partial provider settings")
    func applySettingsMergesExplicitBuiltInPathsIntoPartialProviderSettings() {
        let queue = TaskQueue(poolSize: 2)
        queue.applySettings(
            claudePath: "/custom/bin/claude",
            copilotPath: "/custom/bin/copilot",
            providerSettings: AgentRuntimeProviderSettings(),
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 300,
            validationModel: "haiku"
        )

        for worker in queue.workers {
            #expect(worker.executablePath(for: .claudeCode) == "/custom/bin/claude")
            #expect(worker.executablePath(for: .copilotCLI) == "/custom/bin/copilot")
            #expect(worker.homeDirectory(for: .copilotCLI) == CopilotCLIRuntime.channelHome())
        }
    }

    @Test("cancelAll clears dispatched and active state")
    @MainActor
    func cancelAllClearsAll() {
        let queue = TaskQueue(poolSize: 2)
        queue.activeTasks.insert(UUID())
        queue.cancelAll()
        #expect(queue.activeTasks.isEmpty)
        #expect(!queue.isProcessing)
    }

    @Test("write locks serialize tasks for the same execution root")
    func writeLocksSerializeSameExecutionRoot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Locks", primaryPath: root)
        let first = AgentTask(title: "First", goal: "Edit files", workspace: workspace)
        let second = AgentTask(title: "Second", goal: "Edit other files", workspace: workspace)
        let queue = TaskQueue(poolSize: 2)

        let firstClaim = try #require(queue.acquireResourceLockIfAvailable(
            task: first,
            accessMode: .write,
            runMode: "task"
        ))

        #expect(!queue.canAcquireResourceLock(for: second, accessMode: .write))
        #expect(queue.acquireResourceLockIfAvailable(task: second, accessMode: .write, runMode: "task") == nil)

        queue.releaseResourceLock(firstClaim, task: first)
        #expect(queue.canAcquireResourceLock(for: second, accessMode: .write))
    }

    @Test("write locks serialize duplicate runs for the same task")
    func writeLocksSerializeDuplicateRunsForSameTask() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Duplicate Locks", primaryPath: root)
        let task = AgentTask(title: "Single task", goal: "Edit files", workspace: workspace)
        let queue = TaskQueue(poolSize: 2)

        let firstClaim = try #require(queue.acquireResourceLockIfAvailable(
            task: task,
            accessMode: .write,
            runMode: "task"
        ))

        #expect(!queue.canAcquireResourceLock(for: task, accessMode: .write))
        #expect(queue.acquireResourceLockIfAvailable(task: task, accessMode: .write, runMode: "continue") == nil)

        queue.releaseResourceLock(firstClaim, task: task)
        #expect(queue.canAcquireResourceLock(for: task, accessMode: .write))
    }

    @Test("read-only locks share roots while writers wait")
    func readOnlyLocksShareRootsWhileWritersWait() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Read Locks", primaryPath: root)
        let readerA = AgentTask(title: "Review A", goal: "Read files", workspace: workspace)
        let readerB = AgentTask(title: "Review B", goal: "Read more files", workspace: workspace)
        let writer = AgentTask(title: "Patch", goal: "Write files", workspace: workspace)
        let queue = TaskQueue(poolSize: 3)

        let readerClaim = try #require(queue.acquireResourceLockIfAvailable(
            task: readerA,
            accessMode: .readOnly,
            runMode: "verifier"
        ))

        #expect(queue.canAcquireResourceLock(for: readerB, accessMode: .readOnly))
        #expect(queue.acquireResourceLockIfAvailable(task: readerB, accessMode: .readOnly, runMode: "research") != nil)
        #expect(!queue.canAcquireResourceLock(for: writer, accessMode: .write))

        queue.releaseResourceLock(readerClaim, task: readerA)
        #expect(!queue.canAcquireResourceLock(for: writer, accessMode: .write))
    }

    @Test("resource access classifier honors explicit read-only declarations")
    func resourceAccessClassifierHonorsExplicitReadOnlyDeclarations() {
        let queue = TaskQueue(poolSize: 2)
        let readOnly = AgentTask(title: "Verifier", goal: "Check the diff")
        readOnly.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        let writeDefault = AgentTask(title: "Worker", goal: "Patch the code")

        #expect(queue.resourceAccess(for: readOnly) == .readOnly)
        #expect(queue.resourceAccess(for: writeDefault) == .write)
    }

    @Test("write locks allow parallel work on different execution roots")
    func writeLocksAllowDifferentExecutionRoots() throws {
        let firstRoot = try temporaryRoot()
        let secondRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: firstRoot)
            try? FileManager.default.removeItem(atPath: secondRoot)
        }
        let first = AgentTask(title: "First", goal: "Edit files", workspace: Workspace(name: "A", primaryPath: firstRoot))
        let second = AgentTask(title: "Second", goal: "Edit files", workspace: Workspace(name: "B", primaryPath: secondRoot))
        let queue = TaskQueue(poolSize: 2)

        _ = try #require(queue.acquireResourceLockIfAvailable(task: first, accessMode: .write, runMode: "task"))

        #expect(queue.canAcquireResourceLock(for: second, accessMode: .write))
        #expect(queue.acquireResourceLockIfAvailable(task: second, accessMode: .write, runMode: "task") != nil)
        #expect(queue.activeResourceLocks.count == 2)
    }

    @Test("write locks serialize ancestor and descendant execution roots")
    func writeLocksSerializeAncestorAndDescendantExecutionRoots() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let childRoot = (root as NSString).appendingPathComponent("packages/app")
        try FileManager.default.createDirectory(atPath: childRoot, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Nested Locks", primaryPath: root)
        let parentTask = AgentTask(title: "Parent", goal: "Patch root", workspace: workspace)
        let childTask = AgentTask(title: "Child", goal: "Patch package", workspace: workspace)
        childTask.executionRootPath = childRoot
        let queue = TaskQueue(poolSize: 2)

        let parentClaim = try #require(queue.acquireResourceLockIfAvailable(
            task: parentTask,
            accessMode: .write,
            runMode: "task"
        ))

        #expect(!queue.canAcquireResourceLock(for: childTask, accessMode: .write))
        #expect(queue.acquireResourceLockIfAvailable(task: childTask, accessMode: .write, runMode: "task") == nil)

        queue.releaseResourceLock(parentClaim, task: parentTask)
        #expect(queue.canAcquireResourceLock(for: childTask, accessMode: .write))
    }

    @Test("resource lock events are persisted for later audit")
    func resourceLockEventsArePersistedForAudit() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeQueueLockContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Audit Locks", primaryPath: root)
        let task = AgentTask(title: "Audit", goal: "Edit files", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let queue = TaskQueue(poolSize: 1)

        let claim = try #require(queue.acquireResourceLockIfAvailable(
            task: task,
            accessMode: .write,
            runMode: "task",
            modelContext: context
        ))
        queue.releaseResourceLock(claim, task: task, modelContext: context)

        #expect(task.events.contains { $0.type == TaskResourceLockEventTypes.acquired })
        #expect(task.events.contains { $0.type == TaskResourceLockEventTypes.released })
        #expect(task.events.allSatisfy { $0.category == "lifecycle" })
    }

    @Test("executeTask rejects non-queued tasks before worker assignment")
    func executeTaskRejectsNonQueuedTasksBeforeWorkerAssignment() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeQueueLockContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Admission", primaryPath: root)
        let task = AgentTask(title: "Already done", goal: "Do not launch", workspace: workspace)
        task.status = .completed
        let completedAt = Date(timeIntervalSince1970: 1_000)
        task.completedAt = completedAt
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let queue = TaskQueue(poolSize: 1)
        await queue.executeTask(task, modelContext: context)

        #expect(task.status == .completed)
        #expect(task.completedAt == completedAt)
        #expect(task.runs.isEmpty)
        #expect(queue.worker(for: task) == nil)
        #expect(queue.activeTasks.isEmpty)
        #expect(task.events.contains {
            $0.type == TaskEventTypes.System.error.rawValue
                && $0.payload.contains("could not be admitted")
        })
    }

    @Test("approved plan next-step finalization admits queued task before completion")
    func approvedPlanNextStepFinalizationAdmitsQueuedTaskBeforeCompletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeQueueLockContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Approved Plan", primaryPath: root)
        let task = AgentTask(title: "Plan", goal: "Finalize plan", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Completed plan",
            goal: "Finalize without launching another worker step",
            steps: [
                TaskPlanPayloadStep(id: "done", title: "Already done", status: .done)
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        try context.save()

        let queue = TaskQueue(poolSize: 1)
        await queue.executeApprovedPlan(
            task: task,
            plan: plan,
            mode: .nextStep,
            modelContext: context
        )

        #expect(task.status == .completed)
        #expect(task.runs.isEmpty)
        #expect(queue.worker(for: task) == nil)
        #expect(queue.activeTasks.isEmpty)
        #expect(task.events.contains { $0.type == TaskPlanEventTypes.executionCompleted })
    }
}

private func temporaryRoot() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-resource-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

// MARK: - Task Folder

@Suite("Task Folder")
struct TaskFolderTests {

    @Test("taskFolder returns empty when no workspace")
    func noWorkspace() {
        let task = makeTask()
        #expect(TaskWorkspaceAccess(task: task).taskFolder == "")
    }

    @Test("taskFolder includes short task ID")
    func includesShortID() {
        let task = makeTask()
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        task.workspace = ws
        let shortID = String(task.id.uuidString.prefix(8))
        #expect(TaskWorkspaceAccess(task: task).taskFolder == "/tmp/test-ws/.astra/tasks/\(shortID)")
    }

    @Test("taskFolder reads legacy location until migrated")
    func legacyReadableFolder() throws {
        let tmpDir = "/tmp/astra-legacy-task-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let task = makeTask()
        let ws = Workspace(name: "Test", primaryPath: tmpDir)
        task.workspace = ws
        let legacy = WorkspaceFileLayout.legacyTaskFolder(workspacePath: tmpDir, taskID: task.id)
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)

        #expect(TaskWorkspaceAccess(task: task).taskFolder == legacy)

        let migrated = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(migrated == WorkspaceFileLayout.taskFolder(workspacePath: tmpDir, taskID: task.id))
        #expect(FileManager.default.fileExists(atPath: migrated))
        #expect(!FileManager.default.fileExists(atPath: legacy))
    }

    @Test("Different tasks get different folders")
    func uniqueFolders() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        let task1 = makeTask(title: "Task 1")
        task1.workspace = ws
        let task2 = makeTask(title: "Task 2")
        task2.workspace = ws
        #expect(TaskWorkspaceAccess(task: task1).taskFolder != TaskWorkspaceAccess(task: task2).taskFolder)
    }

    @Test("ensureTaskFolder creates directory on disk")
    func ensureCreates() throws {
        let tmpDir = "/tmp/astra-test-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let task = makeTask()
        let ws = Workspace(name: "Test", primaryPath: tmpDir)
        task.workspace = ws

        let path = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(!path.isEmpty)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent("outputs"),
            isDirectory: &isDir
        ))
        #expect(isDir.boolValue)
    }

    @Test("TaskWorkspaceAccess creates task directories through injected file system")
    func ensureCreatesThroughInjectedFileSystem() throws {
        let task = makeTask()
        let ws = Workspace(name: "Test", primaryPath: "/tmp/astra-mock-\(UUID().uuidString.prefix(8))")
        task.workspace = ws
        let fileSystem = MockFileSystem()

        let path = try TaskWorkspaceAccess(task: task).ensureTaskFolder(fileSystem: fileSystem)

        #expect(path == WorkspaceFileLayout.taskFolder(workspacePath: ws.primaryPath, taskID: task.id))
        #expect(fileSystem.createdDirectories.map(\.path) == [
            path,
            (path as NSString).appendingPathComponent("outputs")
        ])
    }

    @Test("codeWorkingDirectory uses injected file-system existence")
    func codeWorkingDirectoryUsesInjectedFileSystem() {
        let primary = "/tmp/astra-primary-\(UUID().uuidString.prefix(8))"
        let pinned = "/tmp/astra-pinned-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Test", primaryPath: primary)
        let task = makeTask()
        task.workspace = workspace
        task.executionRootPath = pinned

        let fileSystem = MockFileSystem()
        #expect(TaskWorkspaceAccess(task: task, fileSystem: fileSystem).codeWorkingDirectory == primary)

        fileSystem.addExistingPath(pinned)
        #expect(TaskWorkspaceAccess(task: task, fileSystem: fileSystem).codeWorkingDirectory == pinned)
    }

    @Test("Runtime paths keep workspace roots writable and input directories read-only")
    func runtimePathsSeparateWritableRootsFromInputDirectories() {
        let primary = "/tmp/astra-primary-\(UUID().uuidString.prefix(8))"
        let extra = "/tmp/astra-extra-\(UUID().uuidString.prefix(8))"
        let inputDirectory = "/tmp/astra-input-\(UUID().uuidString.prefix(8))"
        let inputFile = "/tmp/astra-file-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Test", primaryPath: primary, additionalPaths: [extra])
        let task = makeTask()
        task.workspace = workspace
        task.inputs = [inputDirectory, inputFile, inputDirectory]

        let fileSystem = MockFileSystem()
        fileSystem.addExistingPath(inputDirectory, isDirectory: true)
        fileSystem.addExistingPath(inputFile, isDirectory: false)

        let access = TaskWorkspaceAccess(task: task, fileSystem: fileSystem)
        #expect(access.runtimeWritablePaths == [extra])
        #expect(access.runtimeReadOnlyInputPaths == [inputDirectory])
    }
}

// MARK: - Isolation Strategy

@Suite("Isolation Strategy on Tasks")
struct IsolationStrategyTests {

    @Test("Default isolation is sameDirectory")
    func defaultIsolation() {
        let task = makeTask()
        #expect(task.isolationStrategy == .sameDirectory)
    }

    @Test("Copy isolation can be set")
    func copyIsolation() {
        let task = makeTask(isolation: .copy)
        #expect(task.isolationStrategy == .copy)
    }

    @Test("Git branch isolation can be set")
    func gitBranchIsolation() {
        let task = makeTask(isolation: .gitBranch)
        #expect(task.isolationStrategy == .gitBranch)
    }
}
