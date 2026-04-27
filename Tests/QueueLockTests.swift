import Testing
import Foundation
@testable import ASTRA

// MARK: - Helper

private func makeTask(
    title: String = "Test Task",
    goal: String = "Do something",
    isolation: IsolationStrategy = .sameDirectory
) -> AgentTask {
    let task = AgentTask(title: title, goal: goal, tokenBudget: 50000, model: "claude-sonnet-4-6")
    task.isolationStrategy = isolation
    return task
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

    @Test("cancelAll clears dispatched and active state")
    @MainActor
    func cancelAllClearsAll() {
        let queue = TaskQueue(poolSize: 2)
        queue.activeTasks.insert(UUID())
        queue.cancelAll()
        #expect(queue.activeTasks.isEmpty)
        #expect(!queue.isProcessing)
    }
}

// MARK: - Task Folder

@Suite("Task Folder")
struct TaskFolderTests {

    @Test("taskFolder returns empty when no workspace")
    func noWorkspace() {
        let task = makeTask()
        #expect(task.taskFolder == "")
    }

    @Test("taskFolder includes short task ID")
    func includesShortID() {
        let task = makeTask()
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        task.workspace = ws
        let shortID = String(task.id.uuidString.prefix(8))
        #expect(task.taskFolder == "/tmp/test-ws/.astra/tasks/\(shortID)")
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

        #expect(task.taskFolder == legacy)

        let migrated = try task.ensureTaskFolder()
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
        #expect(task1.taskFolder != task2.taskFolder)
    }

    @Test("ensureTaskFolder creates directory on disk")
    func ensureCreates() throws {
        let tmpDir = "/tmp/astra-test-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let task = makeTask()
        let ws = Workspace(name: "Test", primaryPath: tmpDir)
        task.workspace = ws

        let path = try task.ensureTaskFolder()
        #expect(!path.isEmpty)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        #expect(isDir.boolValue)
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
