import Testing
import Foundation
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
