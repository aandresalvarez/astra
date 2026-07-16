import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

enum DockerContainerReachability: Equatable, Sendable {
    case running
    case stoppedOrMissing
    case unreachable
}

protocol DockerContainerReachabilityProbing: Sendable {
    func state(containerName: String) async -> DockerContainerReachability
}

struct DockerCLIContainerReachabilityProbe: DockerContainerReachabilityProbing {
    func state(containerName: String) async -> DockerContainerReachability {
        guard containerName.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#,
            options: .regularExpression
        ) != nil else { return .unreachable }

        let inspect = await run(arguments: ["docker", "inspect", "-f", "{{.State.Running}}", containerName])
        if inspect.exitCode == 0 {
            return inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
                ? .running
                : .stoppedOrMissing
        }
        let info = await run(arguments: ["docker", "info", "--format", "{{.ServerVersion}}"])
        return info.exitCode == 0 ? .stoppedOrMissing : .unreachable
    }

    private func run(arguments: [String]) async -> (exitCode: Int32, stdout: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile().prefix(4_096)
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (127, "")
            }
        }.value
    }
}

@MainActor
final class WorkspaceManagedJobBackendLocatorResolver {
    struct Locator: Sendable {
        let jobRootPath: String
        let configuration: WorkspaceToolConfiguration?
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func locator(for request: TaskExternalOperationBackendRequest) -> Locator? {
        let taskID = request.taskID
        var descriptor = FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.id == taskID }
        )
        descriptor.fetchLimit = 1
        guard let task = try? modelContext.fetch(descriptor).first,
              task.runs.contains(where: { $0.id == request.originatingRunID }) else {
            return nil
        }
        let jobRootPath = DockerWorkspaceMCPProjection.jobRootHostPath(task: task)
        guard !jobRootPath.isEmpty else { return nil }

        let environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        let currentDirectory = task.executionRootPath
            ?? task.workspace?.activeWorkingPath
            ?? task.workspace?.primaryPath
            ?? ""
        guard !currentDirectory.isEmpty else {
            return Locator(jobRootPath: jobRootPath, configuration: nil)
        }
        let variables = DockerWorkspaceMCPProjection.environmentVariables(
            task: task,
            environment: environment,
            currentDirectory: currentDirectory,
            runID: request.originatingRunID
        )
        let configuration = try? WorkspaceToolConfiguration.fromEnvironment(variables)
        return Locator(jobRootPath: jobRootPath, configuration: configuration)
    }
}

struct WorkspaceManagedJobExternalOperationBackend:
    TaskExternalOperationObserving,
    TaskExternalOperationCancelling,
    @unchecked Sendable
{
    private let locatorResolver: WorkspaceManagedJobBackendLocatorResolver
    private let reachabilityProbe: any DockerContainerReachabilityProbing

    @MainActor
    init(
        modelContext: ModelContext,
        reachabilityProbe: any DockerContainerReachabilityProbing = DockerCLIContainerReachabilityProbe()
    ) {
        self.locatorResolver = WorkspaceManagedJobBackendLocatorResolver(modelContext: modelContext)
        self.reachabilityProbe = reachabilityProbe
    }

    func observe(
        _ request: TaskExternalOperationBackendRequest
    ) async -> TaskExternalOperationObservation {
        guard request.backendKind == WorkspaceManagedJobStartReceipt.backend,
              let locator = await locatorResolver.locator(for: request) else {
            return TaskExternalOperationObservation(executionState: .unknown, health: .malformed)
        }
        let record: WorkspaceManagedJobRecord
        do {
            record = try WorkspaceManagedJobStore(rootPath: locator.jobRootPath).load(jobID: request.backendJobID)
            guard let receipt = record.startReceipt,
                  receipt.taskID == request.taskID,
                  receipt.runID == request.originatingRunID,
                  receipt.externalIdentity == request.externalIdentity,
                  (try? receipt.validate(jobID: record.jobID)) != nil else {
                return TaskExternalOperationObservation(executionState: .unknown, health: .malformed)
            }
        } catch {
            return TaskExternalOperationObservation(executionState: .unknown, health: .malformed)
        }

        let executionState = Self.executionState(for: record.status)
        guard !executionState.isTerminalObservation,
              let receipt = record.startReceipt else {
            if executionState.isTerminalObservation,
               let configuration = locator.configuration,
               record.startReceipt?.containerName == configuration.containerName {
                let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
                let manager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)
                let cleaned = manager.cleanupExecutorIfIdle()
                AppLogger.audit(.taskCompleted, category: "ExternalOperation", taskID: request.taskID, fields: [
                    "operation": "cleanup_terminal_local_executor",
                    "backend": request.backendKind,
                    "result": cleaned ? "stopped_or_absent" : "preserved"
                ])
            }
            return TaskExternalOperationObservation(executionState: executionState, health: .healthy)
        }

        switch await reachabilityProbe.state(containerName: receipt.containerName) {
        case .running:
            return TaskExternalOperationObservation(executionState: executionState, health: .healthy)
        case .stoppedOrMissing:
            // This is local Docker execution. A definitively missing/stopped
            // container with no terminal result means interruption; it must
            // never be relaunched by observation.
            return TaskExternalOperationObservation(executionState: .interrupted, health: .healthy)
        case .unreachable:
            return TaskExternalOperationObservation(executionState: .unknown, health: .unreachable)
        }
    }

    func cancel(
        _ request: TaskExternalOperationBackendRequest
    ) async -> TaskExternalOperationObservation {
        guard request.backendKind == WorkspaceManagedJobStartReceipt.backend,
              let locator = await locatorResolver.locator(for: request),
              let configuration = locator.configuration else {
            return TaskExternalOperationObservation(executionState: .unknown, health: .unreachable)
        }
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
        let manager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)
        let record = manager.cancel(jobID: request.backendJobID)
        let state = Self.executionState(for: record.status)
        return TaskExternalOperationObservation(
            executionState: state,
            health: record.status == .failed && record.startReceipt == nil ? .malformed : .healthy
        )
    }

    private static func executionState(
        for status: WorkspaceManagedJobStatus
    ) -> TaskExternalOperationExecutionState {
        switch status {
        case .queued: .queued
        case .running: .running
        case .succeeded: .processCompleted
        case .failed: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        }
    }
}
