import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@MainActor
@Suite("Shared execution environment mounts")
struct ExecutionEnvironmentSharedMountTests {
    @Test("Shared Docker plans downgrade inherited exclusive workspace mounts")
    func sharedDockerPlanDowngradesInheritedWorkspaceMounts() throws {
        let root = try makeTempDir("docker-shared-inherited-mounts")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspacePath = (root as NSString).appendingPathComponent("workspace")
        let additionalPath = (root as NSString).appendingPathComponent("checkout")
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: additionalPath, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Docker", primaryPath: workspacePath, additionalPaths: [additionalPath])
        let task = AgentTask(title: "Research", goal: "Read the project", workspace: workspace)
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let environment = WorkspaceExecutionEnvironment(
            id: "image:stale",
            kind: .dockerImage,
            displayName: "Stale snapshot",
            image: "astra/test:latest",
            mounts: [
                ExecutionEnvironmentMount(hostPath: workspacePath, containerPath: "/workspace", access: .readWrite, role: .workspace),
                ExecutionEnvironmentMount(hostPath: additionalPath, containerPath: "/mnt/astra/path-1", access: .readWrite, role: .additionalPath),
                ExecutionEnvironmentMount(hostPath: taskFolder, containerPath: "/astra/task", access: .readWrite, role: .taskFolder)
            ]
        )

        let mounts = DockerExecutionPlanner.mountPlan(
            currentDirectory: workspacePath,
            environment: environment,
            task: task,
            workspaceAccess: .shared
        )

        #expect(mounts.first { $0.hostPath == workspacePath }?.access == .readOnly)
        #expect(mounts.first { $0.hostPath == additionalPath }?.access == .readOnly)
        #expect(mounts.first { $0.hostPath == taskFolder }?.access == .readWrite)
    }

    private func makeTempDir(_ name: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-(name)-(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
