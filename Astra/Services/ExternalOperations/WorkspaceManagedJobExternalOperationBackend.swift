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

    private func run(
        arguments: [String],
        timeout: TimeInterval = 15
    ) async -> (exitCode: Int32, stdout: String) {
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
            } catch {
                return (127, "")
            }
            // Bound the wait. `docker inspect`/`docker info` can hang
            // indefinitely when the daemon or socket is unresponsive, and
            // `runDueChecks` awaits every spawned probe — so one hung probe would
            // stall the whole scheduler and leave every operation unreconciled.
            // Terminate the subprocess after the timeout and report failure; the
            // caller maps a non-zero exit to `.unreachable`.
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !process.isRunning else {
                process.terminate()
                return (124, "")
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile().prefix(4_096)
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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

    /// Whether the operation's ORIGINATING provider run is still executing.
    /// While it is, its still-connected MCP helper shares the task/run-scoped
    /// executor container (ordinary `workspace_shell` calls run in it), so the
    /// monitor must not `docker stop` it out from under that session — the
    /// helper's own session-end cleanup releases the container once the
    /// provider exits, with the same fail-closed nonterminal-job check.
    func originatingRunIsActive(for request: TaskExternalOperationBackendRequest) -> Bool {
        let runID = request.originatingRunID
        var descriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.id == runID }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first)?.status == .running
    }
}

struct WorkspaceManagedJobExternalOperationBackend:
    TaskExternalOperationObserving,
    TaskExternalOperationCancelling,
    TaskExternalOperationOwnershipValidating,
    @unchecked Sendable
{
    /// The launch itself times out at 30s (`WorkspaceManagedJob.swift`'s
    /// `docker exec -d` call); this is a generous multiple of that so a slow
    /// but genuinely in-flight launch is never misclassified.
    private static let queuedLaunchGracePeriod: TimeInterval = 5 * 60
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

        var executionState = Self.executionState(for: record.status)
        // A record can persist as `.queued` forever if the MCP helper died
        // between `store.create` and the actual `docker exec -d` launch: the
        // job never runs, never produces a heartbeat/result, and nothing here
        // observes the specific (never-started) process — only the SHARED
        // executor container's reachability, which is up regardless. Without
        // this, the task waits `waitingExternal` silently forever. Treat
        // prolonged queuing as an interruption so a real terminal wake fires.
        if executionState == .queued,
           Date().timeIntervalSince(record.createdAt) > Self.queuedLaunchGracePeriod {
            executionState = .interrupted
        }
        guard !executionState.isTerminalObservation,
              let receipt = record.startReceipt else {
            if executionState.isTerminalObservation,
               let configuration = locator.configuration,
               record.startReceipt?.containerName == configuration.containerName,
               // The originating provider session shares this container for its
               // ordinary workspace_shell calls; stopping it mid-session would
               // fail or kill unrelated provider work. Defer to the helper's
               // own session-end cleanup while that run is still executing.
               await !locatorResolver.originatingRunIsActive(for: request) {
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
        // `.failed` with no receipt is DockerWorkspaceJobManager's synthetic
        // fallback for a load/save failure BEFORE any kill was attempted — not a
        // confirmed cancellation. Reporting it as a computed terminal state (as
        // the old code did) would commit it as authoritative: the monitor stops
        // polling forever and may deliver a "failed" wake for a job that was
        // never touched by this cancel attempt and could still be running.
        // Mirror the same unknown/malformed shape `observe()` already uses for
        // an unreadable record instead.
        guard record.status != .failed || record.startReceipt != nil else {
            return TaskExternalOperationObservation(executionState: .unknown, health: .malformed)
        }
        let state = Self.executionState(for: record.status)
        if state.isTerminalObservation,
           // Same originating-session guard as the observed-terminal path: the
           // still-connected MCP helper shares this container for ordinary
           // workspace_shell calls, and its own session-end cleanup releases
           // the container once the provider exits.
           await !locatorResolver.originatingRunIsActive(for: request) {
            // A confirmed cancellation is terminal and never polled again. The
            // originating provider's cleanup preserved this task/run executor
            // container while the job was still nonterminal, so — mirroring the
            // observed-terminal path above — release it now that it is idle.
            // cleanupExecutorIfIdle fails closed (keeps the container if it may
            // still own other trusted work).
            _ = manager.cleanupExecutorIfIdle()
        }
        return TaskExternalOperationObservation(executionState: state, health: .healthy)
    }

    func validateOwnership(_ request: TaskExternalOperationBackendRequest) async -> Bool {
        guard request.backendKind == WorkspaceManagedJobStartReceipt.backend,
              let locator = await locatorResolver.locator(for: request),
              let record = try? WorkspaceManagedJobStore(rootPath: locator.jobRootPath)
                .load(jobID: request.backendJobID),
              let receipt = record.startReceipt,
              receipt.taskID == request.taskID,
              receipt.runID == request.originatingRunID,
              receipt.externalIdentity == request.externalIdentity,
              (try? receipt.validate(jobID: record.jobID)) != nil else {
            return false
        }
        return true
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
