import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Puts `astra-workspace-job` on a native-shell SSH run's PATH, next to the
/// task's `ssh` wrapper (docs/specs/2026-10-21-ssh-remote-managed-jobs.md).
///
/// The helper has exactly the authority of the `ssh <target> '<command>'` it
/// replaces, so it is written only where that command already works: the
/// native-shell route, for the targets the route lists (each one the policy
/// guard allows `ssh` to). Every other route removes a shim an earlier launch
/// left behind, so a run never inherits a helper it was not offered.
@MainActor
enum RemoteWorkspaceJobShim {
    nonisolated static let commandName = "astra-workspace-job"

    nonisolated static var helperPath: String {
        (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent(commandName)
    }

    /// The route as the run will use it: `remoteJobs` is true only when the
    /// shim is now in place, which is what the run line reads.
    static func prepare(
        task: AgentTask,
        runID: UUID,
        route: RemoteWorkspaceSSHRoute?,
        fileManager: FileManager = .default,
        helperPath: String = helperPath
    ) -> RemoteWorkspaceSSHRoute? {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard let route else {
            remove(taskFolder: taskFolder, fileManager: fileManager)
            return nil
        }
        let connections = offeredConnections(task: task, targets: route.targets)
        guard route.route == .nativeShell,
              !taskFolder.isEmpty,
              !connections.isEmpty,
              fileManager.isExecutableFile(atPath: helperPath),
              helperPath.rangeOfCharacter(from: .newlines) == nil else {
            remove(taskFolder: taskFolder, fileManager: fileManager)
            return route.offeringRemoteJobs(false)
        }

        let binDirectory = (taskFolder as NSString).appendingPathComponent(".runtime-bin")
        let shimPath = (binDirectory as NSString).appendingPathComponent(commandName)
        let script = shimScript(
            helperPath: helperPath,
            recordRoot: (taskFolder as NSString).appendingPathComponent("remote-jobs"),
            sshWrapper: (binDirectory as NSString).appendingPathComponent("ssh"),
            connections: connections,
            taskID: task.id,
            runID: runID
        )
        do {
            try fileManager.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binDirectory)
            try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimPath)
        } catch {
            AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                "source": "remote_workspace_jobs",
                "result": "shim_failed",
                "error": error.localizedDescription
            ], level: .warning)
            remove(taskFolder: taskFolder, fileManager: fileManager)
            return route.offeringRemoteJobs(false)
        }
        AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
            "source": "remote_workspace_jobs",
            "result": "shim_ready",
            "connections": String(connections.count)
        ], level: .debug)
        return route.offeringRemoteJobs(true)
    }

    /// The workspace's connections whose `ssh` target the route lists, with
    /// the argv the helper hands to `ssh`. Tildes are expanded here because
    /// the helper runs `ssh` directly, without a shell to expand them.
    static func offeredConnections(task: AgentTask, targets: [String]) -> [RemoteWorkspaceJobShimConnection] {
        guard let workspace = task.workspace else { return [] }
        let offered = Set(targets)
        var seen: Set<String> = []
        return SSHConnectionManager.load(workspacePath: workspace.primaryPath).compactMap { connection in
            let target = RemoteWorkspaceSSHRoute.connectTarget(for: connection)
            guard offered.contains(target), seen.insert(target).inserted else { return nil }
            return RemoteWorkspaceJobShimConnection(
                id: connection.id.uuidString,
                name: connection.displayLabel,
                target: target,
                arguments: connection.sshDestinationArguments(expandingTilde: true)
            )
        }
    }

    static func shimScript(
        helperPath: String,
        recordRoot: String,
        sshWrapper: String,
        connections: [RemoteWorkspaceJobShimConnection],
        taskID: UUID,
        runID: UUID
    ) -> String {
        """
        #!/bin/sh
        export ASTRA_REMOTE_JOB_ROOT=\(shellQuoted(recordRoot))
        export ASTRA_REMOTE_JOB_SSH=\(shellQuoted(sshWrapper))
        export ASTRA_REMOTE_JOB_CONNECTIONS=\(shellQuoted(connectionsJSON(connections)))
        export ASTRA_REMOTE_JOB_TASK_ID=\(shellQuoted(taskID.uuidString))
        export ASTRA_REMOTE_JOB_RUN_ID=\(shellQuoted(runID.uuidString))
        exec \(shellQuoted(helperPath)) "$@"
        """
    }

    /// The wire format `RemoteWorkspaceJobConfiguration.fromEnvironment` reads.
    static func connectionsJSON(_ connections: [RemoteWorkspaceJobShimConnection]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(connections) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func remove(taskFolder: String, fileManager: FileManager) {
        guard !taskFolder.isEmpty else { return }
        let shimPath = ((taskFolder as NSString).appendingPathComponent(".runtime-bin") as NSString)
            .appendingPathComponent(commandName)
        try? fileManager.removeItem(atPath: shimPath)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// The app's copy of `RemoteWorkspaceJobConnection` (the helper's module is
/// not linked into the app); `RemoteWorkspaceJobShimTests` pins the two to
/// one wire format.
struct RemoteWorkspaceJobShimConnection: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var target: String
    var arguments: [String]
}

/// What the policy guard reads an `astra-workspace-job start` as.
enum RemoteWorkspaceJobPolicyEquivalence {
    /// `ssh <connection> <everything after -->` for a command that starts a
    /// remote job anywhere in it, or `nil`. Deliberately loose: it only feeds
    /// an extra denial check, so reading too much as a job start can deny
    /// more, never allow more.
    static func sshEquivalent(of command: String) -> String? {
        guard let start = command.range(
            of: #"(^|[\s;&|(/`])astra-workspace-job\s+start(\s|$)"#,
            options: .regularExpression
        ) else { return nil }
        let arguments = command[start.upperBound...]
        guard let separator = arguments.range(of: #"(^|\s)--(\s|$)"#, options: .regularExpression) else { return nil }
        let options = arguments[..<separator.lowerBound]
        let remote = arguments[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        var target = ""
        if let match = options.range(of: #"--connection(=|\s+)\S+"#, options: .regularExpression) {
            target = String(options[match])
                .replacingOccurrences(of: #"^--connection(=|\s+)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return (["ssh", target, remote].filter { !$0.isEmpty }).joined(separator: " ")
    }
}
