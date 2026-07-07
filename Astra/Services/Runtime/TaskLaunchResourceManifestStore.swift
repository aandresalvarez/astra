import Foundation
import ASTRAModels
import ASTRAPersistence

enum TaskLaunchResourceManifestStore {
    static let latestManifestFileName = "run_resource_manifest.json"

    @discardableResult
    static func persist(
        _ plan: TaskLaunchResourcePlan,
        task: AgentTask,
        fileManager: FileManager = .default
    ) -> String? {
        let access = TaskWorkspaceAccess(task: task)
        guard let taskFolder = try? access.ensureTaskFolder(),
              !taskFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let diagnosticsDirectory = URL(fileURLWithPath: taskFolder)
            .appendingPathComponent("diagnostics", isDirectory: true)
        do {
            try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(plan)
            let latestURL = diagnosticsDirectory
                .appendingPathComponent(latestManifestFileName)
            try data.write(to: latestURL, options: .atomic)

            let runPrefix = plan.runID.map { String($0.uuidString.prefix(8)) } ?? "pending"
            let runURL = diagnosticsDirectory
                .appendingPathComponent("run_resource_manifest_\(runPrefix).json")
            try data.write(to: runURL, options: .atomic)

            AppLogger.audit(.runtimeResourcesPlanned, category: "Worker", taskID: task.id, fields: [
                "manifest_path": latestURL.path,
                "run_manifest_path": runURL.path,
                "host_readable_count": String(plan.hostReadablePaths.count),
                "host_writable_count": String(plan.hostWritablePaths.count),
                "container_mount_count": String(plan.containerMounts.count),
                "credential_label_count": String(plan.credentialGrants.count),
                "diagnostic_count": String(plan.diagnostics.count),
                "provider_placement": plan.providerPlacement,
                "workspace_command_placement": plan.workspaceCommandPlacement,
                "shell_route": plan.shellRoute
            ], level: .debug, fieldMaxLength: 240)
            return latestURL.path
        } catch {
            AppLogger.audit(.runtimeResourcesPlanned, category: "Worker", taskID: task.id, fields: [
                "result": "manifest_write_failed",
                "error_type": String(describing: type(of: error)),
                "error": error.localizedDescription
            ], level: .warning, fieldMaxLength: 240)
            return nil
        }
    }

    static func loadLatest(
        task: AgentTask,
        fileManager: FileManager = .default
    ) -> TaskLaunchResourcePlan? {
        let path = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(latestManifestFileName)
            .path
        guard fileManager.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? decoder.decode(TaskLaunchResourcePlan.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
