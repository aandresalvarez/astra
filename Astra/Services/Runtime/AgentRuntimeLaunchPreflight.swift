import Foundation
import SwiftData
import ASTRACore

struct AgentRuntimeLaunchPreflightResult: Sendable, Equatable {
    enum Status: String, Sendable {
        case taskFolderPrepared
        case taskFolderCreateFailed
        case runtimeReadinessPassed
        case runtimeReadinessFailed
        case credentialProjectionPassed
        case credentialProjectionFailed
        case remoteWorkspacePreflightPassed
        case capabilityRuntimeResourcesPassed
        case capabilityRuntimeResourcesMissing
        case connectorPreflightPassed
        case connectorPreflightFailed
        case connectorCredentialApprovalRequired
        case dockerImageAvailabilityPassed
        case dockerImageAvailabilityFailed
    }

    var status: Status
    var phase: RunPhase
    var reason: String?
    var detail: String?
    var auditFields: [String: String]

    var didPass: Bool {
        switch status {
        case .taskFolderPrepared,
             .runtimeReadinessPassed,
             .credentialProjectionPassed,
             .remoteWorkspacePreflightPassed,
             .capabilityRuntimeResourcesPassed,
             .connectorPreflightPassed,
             .dockerImageAvailabilityPassed:
            return true
        case .taskFolderCreateFailed,
             .runtimeReadinessFailed,
             .credentialProjectionFailed,
             .capabilityRuntimeResourcesMissing,
             .connectorPreflightFailed,
             .connectorCredentialApprovalRequired,
             .dockerImageAvailabilityFailed:
            return false
        }
    }
}

@MainActor
enum AgentRuntimeLaunchPreflight {
    static func prepareTaskFolderForLaunchResult(
        _ task: AgentTask,
        modelContext: ModelContext,
        phase: RunPhase
    ) -> AgentRuntimeLaunchPreflightResult {
        do {
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            let fields = [
                "event": "task_folder_prepared",
                "phase": phase.rawValue,
                "folder_available": String(!folder.isEmpty),
                "result": AgentRuntimeLaunchPreflightResult.Status.taskFolderPrepared.rawValue
            ]
            AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: fields, level: .debug)
            return AgentRuntimeLaunchPreflightResult(
                status: .taskFolderPrepared,
                phase: phase,
                reason: nil,
                detail: folder,
                auditFields: fields
            )
        } catch {
            let reason = "task_folder_create_failed"
            let fields = [
                "reason": reason,
                "phase": phase.rawValue,
                "error_type": String(describing: type(of: error)),
                "error_description": error.localizedDescription,
                "result": AgentRuntimeLaunchPreflightResult.Status.taskFolderCreateFailed.rawValue
            ]
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: fields, level: .error)
            let now = Date()
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: now)
            modelContext.insert(TaskEvent(
                task: task,
                type: "error",
                payload: "ASTRA could not create this task's output folder before launching the agent: \(error.localizedDescription)"
            ))
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            return AgentRuntimeLaunchPreflightResult(
                status: .taskFolderCreateFailed,
                phase: phase,
                reason: reason,
                detail: error.localizedDescription,
                auditFields: fields
            )
        }
    }

    static func prepareTaskFolderForLaunch(
        _ task: AgentTask,
        modelContext: ModelContext,
        phase: RunPhase
    ) -> Bool {
        prepareTaskFolderForLaunchResult(task, modelContext: modelContext, phase: phase).didPass
    }

    static func preflightConnectorsBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        contextText: String,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        runtimeConfiguration: AgentRuntimeConfiguration? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        preflightCache: PreflightCache = PreflightCache(),
        mcpDetectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        mcpIsExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> AgentRuntimeLaunchPreflightResult {
        let resolutionSnapshot = capabilityResolutionSnapshot ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? []
        )
        let capabilityResult = await preflightCapabilitiesBeforeLaunchResultWithPrerequisiteChecks(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText,
            preflightCache: preflightCache,
            capabilityResolutionSnapshot: resolutionSnapshot,
            mcpDetectExecutable: mcpDetectExecutable,
            mcpIsExecutableFile: mcpIsExecutableFile,
            runtimeProfile: runtimeProfileProvider(runtimeConfiguration)
        )
        guard capabilityResult.didPass else {
            return capabilityResult
        }

        let fullContext = [
            task.goal,
            task.title,
            contextText
        ].joined(separator: "\n")
        let scopedConnectors = resolutionSnapshot.providerLaunch.connectors
        // Service-agnostic credential presence check. Non-blocking — the
        // agent may not need every projected connector — but a connector
        // with declared, unloadable credentials must not fail silently.
        let credentialProjection = ConnectorRuntimeProjection(
            connectors: scopedConnectors,
            secretStore: secretStore,
            credentialExposurePolicy: .approvedLabels(
                Set(TaskRuntimePermissionGrants.approvedCredentialLabels(
                    for: task,
                    additionalGrants: executionPolicy.permissionGrantsOverride ?? []
                ))
            )
        )
        let missingCredentials = credentialProjection
            .missingCredentialKeysByConnector()
        if !missingCredentials.isEmpty {
            var warningFields = CapabilityAudit.taskContextFields(
                source: "connector_credential_preflight",
                task: task,
                scope: .providerLaunch(contextText: contextText)
            )
            warningFields["phase"] = phase.rawValue
            warningFields["result"] = "credentials_missing"
            warningFields["connector_names"] = CapabilityAudit.compactNames(missingCredentials.map(\.connector.name))
            warningFields["missing_key_names"] = missingCredentials
                .flatMap(\.missingKeys)
                .sorted()
                .joined(separator: ",")
            AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: warningFields, level: .warning, fieldMaxLength: 240)
        }
        if let credentialLabel = credentialProjection.unapprovedCredentialLabelsRequiringApproval().first {
            return finishPreLaunchCredentialApprovalRequest(
                task: task,
                run: run,
                modelContext: modelContext,
                phase: phase,
                credentialLabel: credentialLabel
            )
        }
        let connectors = ConnectorPreflightService.connectorsRequiringPreflight(
            from: scopedConnectors,
            contextText: fullContext
        )
        let traceID = AuditTrace.make("connector-preflight")
        var preflightFields = CapabilityAudit.taskContextFields(
            source: "connector_preflight_candidates",
            task: task,
            scope: .providerLaunch(contextText: contextText)
        )
        preflightFields["trace_id"] = traceID
        preflightFields["phase"] = phase.rawValue
        preflightFields["preflight_connector_count"] = String(connectors.count)
        AppLogger.audit(.capabilityChatContext, category: "Worker", taskID: task.id, fields: preflightFields, level: .debug, fieldMaxLength: 240)

        guard let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: connectors,
            store: secretStore,
            contextText: fullContext,
            workspaceID: task.workspace?.id,
            traceID: traceID
        ) else {
            let resultFields = [
                "source": "task_preflight",
                "trace_id": traceID,
                "phase": phase.rawValue,
                "workspace_id": task.workspace?.id.uuidString ?? "none",
                "result": "preflight_passed",
                "diagnostic_result": AgentRuntimeLaunchPreflightResult.Status.connectorPreflightPassed.rawValue,
                "connector_count": String(connectors.count),
                "connector_names": CapabilityAudit.compactNames(connectors.map(\.name))
            ]
            if !connectors.isEmpty {
                AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: resultFields, level: .info, fieldMaxLength: 240)
            }
            return AgentRuntimeLaunchPreflightResult(
                status: .connectorPreflightPassed,
                phase: phase,
                reason: nil,
                detail: nil,
                auditFields: resultFields
            )
        }

        var fields = issue.auditFields
        fields["trace_id"] = traceID
        fields["phase"] = phase.rawValue
        fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.connectorPreflightFailed.rawValue
        AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: fields, level: .error)

        let message = """
        \(issue.connectorName) connector check failed before the agent ran:

        \(issue.message)

        Fix this connector in Manage Capabilities, then retry the task. ASTRA stopped here so the agent does not guess about Jira permissions from partial API results.
        """
        finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: modelContext,
            reason: "connector_preflight_failed",
            payload: message
        )
        return AgentRuntimeLaunchPreflightResult(
            status: .connectorPreflightFailed,
            phase: phase,
            reason: "connector_preflight_failed",
            detail: issue.message,
            auditFields: fields
        )
    }

    private static func finishPreLaunchCredentialApprovalRequest(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        credentialLabel: String
    ) -> AgentRuntimeLaunchPreflightResult {
        let request = PermissionRequest.credential(label: credentialLabel)
        let grants = PermissionBroker.approvalGrants(for: request)
        let payload = PermissionBroker.approvalPayloadString(
            providerID: task.resolvedRuntimeID,
            request: request,
            reason: "Connector credential egress requires explicit first-use approval before ASTRA injects it into the provider environment.",
            providerDetail: credentialLabel,
            grants: grants
        )
        let fields: [String: String] = [
            "source": "connector_credential_egress",
            "phase": phase.rawValue,
            "runtime": task.resolvedRuntimeID.rawValue,
            "credential_label": credentialLabel,
            "diagnostic_result": AgentRuntimeLaunchPreflightResult.Status.connectorCredentialApprovalRequired.rawValue,
            "result": "approval_required"
        ]
        run.status = .failed
        run.typedStopReason = .permissionApprovalRequired
        run.completedAt = Date()
        TaskStateMachine.pauseForRuntimePermission(task, modelContext: modelContext, at: run.completedAt ?? Date())
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: payload,
            run: run
        ))
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: fields, level: .warning, fieldMaxLength: 240)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        return AgentRuntimeLaunchPreflightResult(
            status: .connectorCredentialApprovalRequired,
            phase: phase,
            reason: TaskRunStopReason.permissionApprovalRequired.rawValue,
            detail: credentialLabel,
            auditFields: fields
        )
    }

    static func preflightConnectorsBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        contextText: String,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        runtimeConfiguration: AgentRuntimeConfiguration? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        preflightCache: PreflightCache = PreflightCache(),
        mcpDetectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        mcpIsExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> Bool {
        await preflightConnectorsBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText,
            executionPolicy: executionPolicy,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            runtimeConfiguration: runtimeConfiguration,
            secretStore: secretStore,
            preflightCache: preflightCache,
            mcpDetectExecutable: mcpDetectExecutable,
            mcpIsExecutableFile: mcpIsExecutableFile
        ).didPass
    }

    static func preflightRemoteWorkspaceBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        runtime: AgentRuntimeID
    ) -> AgentRuntimeLaunchPreflightResult {
        let buildInfo = AppBuildInfo.current
        var fields = buildInfo.auditFields
        fields.merge([
            "source": "remote_workspace_preflight",
            "phase": phase.rawValue,
            "runtime": runtime.rawValue,
            "diagnostic_result": AgentRuntimeLaunchPreflightResult.Status.remoteWorkspacePreflightPassed.rawValue
        ]) { _, new in new }

        guard let workspace = task.workspace else {
            fields["result"] = "no_workspace"
            return AgentRuntimeLaunchPreflightResult(
                status: .remoteWorkspacePreflightPassed,
                phase: phase,
                reason: nil,
                detail: nil,
                auditFields: fields
            )
        }

        let hasStoredConnections = SSHConnectionManager.hasStoredConnections(workspacePath: workspace.primaryPath)
        fields["workspace_id"] = workspace.id.uuidString
        fields["has_stored_ssh_connections"] = String(hasStoredConnections)
        guard hasStoredConnections else {
            fields["result"] = "no_ssh_connections"
            return AgentRuntimeLaunchPreflightResult(
                status: .remoteWorkspacePreflightPassed,
                phase: phase,
                reason: nil,
                detail: nil,
                auditFields: fields
            )
        }

        let connections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
        let names = connections.map { displayName(for: $0) }
        let aliasNames = connections
            .map(\.configAlias)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        fields["result"] = "ssh_connections_detected"
        fields["ssh_connection_count"] = String(connections.count)
        fields["ssh_connection_names"] = CapabilityAudit.compactNames(names)
        fields["ssh_config_alias_count"] = String(aliasNames.count)
        fields["ssh_config_aliases"] = CapabilityAudit.compactNames(aliasNames)
        fields["provider_path_access_expected"] = "true"

        AppLogger.audit(
            .remoteWorkspacePreflight,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: .info,
            fieldMaxLength: 240
        )

        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: remoteWorkspacePreflightMessage(
                connectionNames: names,
                aliasNames: aliasNames,
                runtime: runtime
            ),
            run: run
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)

        return AgentRuntimeLaunchPreflightResult(
            status: .remoteWorkspacePreflightPassed,
            phase: phase,
            reason: nil,
            detail: names.joined(separator: ", "),
            auditFields: fields
        )
    }

    static func preflightRemoteWorkspaceBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        runtime: AgentRuntimeID
    ) -> Bool {
        preflightRemoteWorkspaceBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            runtime: runtime
        ).didPass
    }

    static func preflightRuntimeReadinessBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        report: RuntimeReadinessReport
    ) -> AgentRuntimeLaunchPreflightResult {
        let blockedChecks = report.checks.filter { $0.state == .blocked }
        var fields: [String: String] = [
            "source": "runtime_readiness_preflight",
            "phase": phase.rawValue,
            "runtime": task.resolvedRuntimeID.rawValue,
            "readiness_state": report.state.rawValue,
            "blocked_check_count": String(blockedChecks.count)
        ]

        guard let blocked = blockedChecks.first else {
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.runtimeReadinessPassed.rawValue
            AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: fields, level: .debug)
            return AgentRuntimeLaunchPreflightResult(
                status: .runtimeReadinessPassed,
                phase: phase,
                reason: nil,
                detail: nil,
                auditFields: fields
            )
        }

        fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.runtimeReadinessFailed.rawValue
        fields["blocked_check_id"] = blocked.id
        fields["blocked_check_title"] = blocked.title
        let message = runtimeReadinessFailureMessage(blocked)
        finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: modelContext,
            reason: "runtime_readiness_failed",
            payload: message
        )
        return AgentRuntimeLaunchPreflightResult(
            status: .runtimeReadinessFailed,
            phase: phase,
            reason: "runtime_readiness_failed",
            detail: blocked.detail,
            auditFields: fields
        )
    }

    static func preflightRuntimeReadinessBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        configuration: RuntimeReadinessConfiguration,
        readinessService: RuntimeReadinessService = RuntimeReadinessService()
    ) async -> Bool {
        let report = await readinessService.check(configuration: configuration)
        return preflightRuntimeReadinessBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            report: report
        ).didPass
    }

    static func preflightCredentialProjectionBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        codeDirectory: String,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> AgentRuntimeLaunchPreflightResult {
        var report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: codeDirectory,
            homeDirectoryPath: homeDirectoryPath,
            fileManager: fileManager
        )
        var fields = report.auditFields
        fields["phase"] = phase.rawValue
        fields["runtime"] = task.resolvedRuntimeID.rawValue
        fields["diagnostic_result"] = report.shouldBlockLaunch
            ? AgentRuntimeLaunchPreflightResult.Status.credentialProjectionFailed.rawValue
            : AgentRuntimeLaunchPreflightResult.Status.credentialProjectionPassed.rawValue
        fields["result"] = report.shouldBlockLaunch ? "blocked" : "passed"

        if report.shouldBlockLaunch,
           autoProjectRequiredDockerCredentialsIfPossible(
               task: task,
               run: run,
               modelContext: modelContext,
               report: report,
               homeDirectoryPath: homeDirectoryPath,
               fileManager: fileManager
           ) {
            report = ExecutionEnvironmentCredentialReadinessService.evaluate(
                task: task,
                codeDirectory: codeDirectory,
                homeDirectoryPath: homeDirectoryPath,
                fileManager: fileManager
            )
            fields = report.auditFields
            fields["phase"] = phase.rawValue
            fields["runtime"] = task.resolvedRuntimeID.rawValue
            fields["auto_projected_credentials"] = "true"
            fields["diagnostic_result"] = report.shouldBlockLaunch
                ? AgentRuntimeLaunchPreflightResult.Status.credentialProjectionFailed.rawValue
                : AgentRuntimeLaunchPreflightResult.Status.credentialProjectionPassed.rawValue
            fields["result"] = report.shouldBlockLaunch ? "blocked_after_auto_projection" : "auto_projected_and_passed"
        }

        guard !report.shouldBlockLaunch else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: fields, level: .error, fieldMaxLength: 240)
            finishPreLaunchFailure(
                task: task,
                run: run,
                modelContext: modelContext,
                reason: TaskRunStopReason.credentialProjectionRequired.rawValue,
                payload: report.userMessage
            )
            return AgentRuntimeLaunchPreflightResult(
                status: .credentialProjectionFailed,
                phase: phase,
                reason: TaskRunStopReason.credentialProjectionRequired.rawValue,
                detail: report.detail,
                auditFields: fields
            )
        }

        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: fields, level: .debug, fieldMaxLength: 240)
        return AgentRuntimeLaunchPreflightResult(
            status: .credentialProjectionPassed,
            phase: phase,
            reason: nil,
            detail: report.detail,
            auditFields: fields
        )
    }

    private static func autoProjectRequiredDockerCredentialsIfPossible(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        report: ExecutionEnvironmentCredentialReadinessReport,
        homeDirectoryPath: String,
        fileManager: FileManager
    ) -> Bool {
        guard report.requiredProjectionIDs.contains(ExecutionEnvironmentCredentialProjection.gcpADCID) else {
            return false
        }
        switch report.state {
        case .hostCredentialAvailableButNotProjected,
             .pinnedTaskSnapshotMissingProjection,
             .projectedButHostCredentialMissing:
            break
        case .notRequired,
             .requiredButHostCredentialMissing,
             .ready,
             .failed:
            return false
        }

        let gcloudDirectory = ExecutionEnvironmentCredentialProjection
            .defaultGCPADCHostPath(homeDirectory: homeDirectoryPath)
        let adcFile = (gcloudDirectory as NSString)
            .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: adcFile, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }

        var environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        guard environment.isContainerized else { return false }

        var projections = environment.effectiveCredentialProjections
        projections.removeAll { $0.id == ExecutionEnvironmentCredentialProjection.gcpADCID }
        projections.append(ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcloudDirectory))
        environment.setCredentialProjections(projections)

        guard let json = ExecutionEnvironmentStore.encodeSnapshot(environment) else {
            return false
        }
        task.executionEnvironmentSnapshotJSON = json
        task.updatedAt = Date()
        run.executionEnvironmentSnapshotJSON = json
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)

        AppLogger.audit(.executionEnvironmentChanged, category: "Worker", taskID: task.id, fields: [
            "result": "auto_projected_required_docker_credentials",
            "credential_projection": ExecutionEnvironmentCredentialProjection.gcpADCID,
            "credential_projection_state": report.state.rawValue,
            "environment": environment.kind.rawValue,
            "environment_id": environment.id,
            "run_id": run.id.uuidString
        ], level: .info)
        return true
    }

    static func preflightDockerImageBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        imageAvailabilityChecker: any DockerImageAvailabilityChecking = DockerImageInventoryService()
    ) async -> AgentRuntimeLaunchPreflightResult {
        let environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        var fields: [String: String] = [
            "source": "docker_image_availability_preflight",
            "phase": phase.rawValue,
            "runtime": task.resolvedRuntimeID.rawValue,
            "execution_environment_kind": environment.kind.rawValue,
            "execution_environment_id": environment.id,
            "execution_environment_provider_placement": environment.effectiveProviderPlacement.rawValue,
            "workspace_command_placement": environment.workspaceCommandPlacement,
            "shell_route": environment.workspaceShellRoute
        ]

        guard environment.isContainerized else {
            fields["result"] = "skipped_host_environment"
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.dockerImageAvailabilityPassed.rawValue
            AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: fields, level: .debug)
            return AgentRuntimeLaunchPreflightResult(
                status: .dockerImageAvailabilityPassed,
                phase: phase,
                reason: nil,
                detail: "Host execution does not require a Docker image.",
                auditFields: fields
            )
        }

        guard let image = environment.image?.trimmingCharacters(in: .whitespacesAndNewlines),
              !image.isEmpty else {
            let reason = TaskRunStopReason.dockerImageUnavailable.rawValue
            fields["result"] = "missing_image_configuration"
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.dockerImageAvailabilityFailed.rawValue
            fields["stop_reason"] = reason
            let message = dockerImagePreflightFailureMessage(
                image: environment.image ?? environment.displayName,
                detail: "The selected Docker execution environment does not have an image configured.",
                remediation: "Build or select a loaded Docker image in the Container panel, then retry the task."
            )
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: fields, level: .error, fieldMaxLength: 240)
            finishPreLaunchFailure(
                task: task,
                run: run,
                modelContext: modelContext,
                reason: reason,
                payload: message
            )
            return AgentRuntimeLaunchPreflightResult(
                status: .dockerImageAvailabilityFailed,
                phase: phase,
                reason: reason,
                detail: message,
                auditFields: fields
            )
        }

        fields["container_image"] = image
        let availability = await imageAvailabilityChecker.checkImageAvailability(image)
        switch availability {
        case .success(let summary):
            fields["result"] = "image_available"
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.dockerImageAvailabilityPassed.rawValue
            fields["container_image_id"] = summary.imageID ?? "unknown"
            AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: fields, level: .debug, fieldMaxLength: 240)
            return AgentRuntimeLaunchPreflightResult(
                status: .dockerImageAvailabilityPassed,
                phase: phase,
                reason: nil,
                detail: summary.imageID,
                auditFields: fields
            )
        case .failure(let error):
            let classification = dockerImagePreflightFailure(for: image, error: error)
            fields["result"] = classification.result
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.dockerImageAvailabilityFailed.rawValue
            fields["stop_reason"] = classification.reason.rawValue
            fields["error_description"] = classification.detail
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: fields, level: .error, fieldMaxLength: 240)
            let message = dockerImagePreflightFailureMessage(
                image: image,
                detail: classification.detail,
                remediation: classification.remediation
            )
            finishPreLaunchFailure(
                task: task,
                run: run,
                modelContext: modelContext,
                reason: classification.reason.rawValue,
                payload: message
            )
            return AgentRuntimeLaunchPreflightResult(
                status: .dockerImageAvailabilityFailed,
                phase: phase,
                reason: classification.reason.rawValue,
                detail: classification.detail,
                auditFields: fields
            )
        }
    }

    static func preflightDockerImageBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) async -> Bool {
        await preflightDockerImageBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase
        ).didPass
    }

    static func preflightCredentialProjectionBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        codeDirectory: String
    ) -> Bool {
        preflightCredentialProjectionBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            codeDirectory: codeDirectory
        ).didPass
    }

    static func preflightCapabilitiesBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        contextText: String = "",
        prerequisiteStatuses: [String: HealthStatus] = [:],
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        mcpDetectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        mcpIsExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        runtimeProfile: (AgentRuntimeID) -> AgentRuntimeCapabilityProfile = {
            AgentRuntimeCapabilityProfileService.profile(for: $0, executablePath: "")
        }
    ) -> AgentRuntimeLaunchPreflightResult {
        let resolutionSnapshot = capabilityResolutionSnapshot ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        )
        let policyContext = task.workspace.map {
            CapabilityCatalogPolicyContext.workspaceUser(
                workspace: $0,
                approvalRecords: CapabilityApprovalStore().records()
            )
        }
        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            prerequisiteStatuses: prerequisiteStatuses,
            policyContext: policyContext,
            scope: .providerLaunch(contextText: contextText),
            capabilityResolutionSnapshot: resolutionSnapshot
        )
        var fields = CapabilityAudit.taskContextFields(
            source: "capability_runtime_integrity",
            task: task,
            scope: .providerLaunch(contextText: contextText)
        )
        fields.merge(AppBuildInfo.current.auditFields) { _, new in new }
        fields["phase"] = phase.rawValue
        fields["result"] = issues.isEmpty ? "passed" : "missing_resources"
        for (key, value) in CapabilityRuntimeIntegrityService.summaryFields(for: issues) {
            fields[key] = value
        }

        // MCP servers are materialized only for runtimes that support them;
        // for those, a stdio server whose command can't be resolved would
        // fail opaquely mid-run, so it blocks the launch here instead.
        let runtime = AgentRuntimeID(rawValue: task.runtimeID ?? "") ?? TaskExecutionDefaults.runtime
        let mcpIssues: [MCPRuntimeProjection.PreflightIssue]
        if runtimeProfile(runtime).supportsTaskScopedMCPDelivery {
            let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
                for: task,
                capabilityScope: resolutionSnapshot.providerLaunch,
                contextText: contextText
            )
            var mcpServers = MCPRuntimeProjection.enabledServers(
                for: task.workspace,
                packages: CapabilityRuntimeResourceMatcher.packageDefinitions(),
                approvalRecords: CapabilityApprovalStore().records()
            )
            let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)
            if let workspaceServer = DockerWorkspaceMCPProjection.resolvedServer(
                task: task,
                environment: executionEnvironment,
                currentDirectory: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
                runID: run.id
            ) {
                mcpServers.append(workspaceServer)
            }
            if let hostControlServer = HostControlPlaneMCPProjection.resolvedServer(
                task: task,
                environment: executionEnvironment,
                currentDirectory: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
                runID: run.id,
                taskEnvironment: taskEnv,
                contextText: contextText,
                capabilityScope: resolutionSnapshot.providerLaunch
            ) {
                mcpServers.append(hostControlServer)
            }
            if let browserServer = BrowserBridgeMCPProjection.resolvedServer(
                for: task,
                contextText: contextText
            ) {
                mcpServers.append(browserServer)
            }
            mcpIssues = MCPRuntimeProjection.preflightIssues(
                servers: mcpServers,
                detectExecutable: mcpDetectExecutable,
                isExecutableFile: mcpIsExecutableFile
            )
        } else {
            mcpIssues = []
        }
        if !mcpIssues.isEmpty {
            fields["result"] = "mcp_server_executable_missing"
            fields["mcp_issue_count"] = String(mcpIssues.count)
        }

        guard !issues.isEmpty || !mcpIssues.isEmpty else {
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.capabilityRuntimeResourcesPassed.rawValue
            AppLogger.audit(.capabilityRuntimeIntegrity, category: "Worker", taskID: task.id, fields: fields, level: .debug, fieldMaxLength: 240)
            return AgentRuntimeLaunchPreflightResult(
                status: .capabilityRuntimeResourcesPassed,
                phase: phase,
                reason: nil,
                detail: nil,
                auditFields: fields
            )
        }

        if issues.isEmpty {
            let detail = mcpIssues.map(\.message).joined(separator: "\n")
            fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.capabilityRuntimeResourcesMissing.rawValue
            AppLogger.audit(.capabilityRuntimeIntegrity, category: "Worker", taskID: task.id, fields: fields, level: .error, fieldMaxLength: 240)
            finishPreLaunchFailure(
                task: task,
                run: run,
                modelContext: modelContext,
                reason: "mcp_server_executable_missing",
                payload: detail
            )
            return AgentRuntimeLaunchPreflightResult(
                status: .capabilityRuntimeResourcesMissing,
                phase: phase,
                reason: "mcp_server_executable_missing",
                detail: detail,
                auditFields: fields
            )
        }

        fields["diagnostic_result"] = AgentRuntimeLaunchPreflightResult.Status.capabilityRuntimeResourcesMissing.rawValue
        AppLogger.audit(.capabilityRuntimeIntegrity, category: "Worker", taskID: task.id, fields: fields, level: .error, fieldMaxLength: 240)
        finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: modelContext,
            reason: "capability_runtime_resources_missing",
            payload: CapabilityRuntimeIntegrityService.userMessage(for: issues)
        )
        return AgentRuntimeLaunchPreflightResult(
            status: .capabilityRuntimeResourcesMissing,
            phase: phase,
            reason: "capability_runtime_resources_missing",
            detail: CapabilityRuntimeIntegrityService.userMessage(for: issues),
            auditFields: fields
        )
    }

    static func preflightCapabilitiesBeforeLaunchResultWithPrerequisiteChecks(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        contextText: String = "",
        preflightCache: PreflightCache = PreflightCache(),
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        mcpDetectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        mcpIsExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        runtimeProfile: (AgentRuntimeID) -> AgentRuntimeCapabilityProfile = {
            AgentRuntimeCapabilityProfileService.profile(for: $0, executablePath: "")
        }
    ) async -> AgentRuntimeLaunchPreflightResult {
        let resolutionSnapshot = capabilityResolutionSnapshot ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        )
        let prerequisiteStatuses = await prerequisiteStatusesBeforeLaunch(
            task: task,
            contextText: contextText,
            preflightCache: preflightCache,
            capabilityResolutionSnapshot: resolutionSnapshot
        )
        return preflightCapabilitiesBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText,
            prerequisiteStatuses: prerequisiteStatuses,
            capabilityResolutionSnapshot: resolutionSnapshot,
            mcpDetectExecutable: mcpDetectExecutable,
            mcpIsExecutableFile: mcpIsExecutableFile,
            runtimeProfile: runtimeProfile
        )
    }

    private static func prerequisiteStatusesBeforeLaunch(
        task: AgentTask,
        contextText: String,
        preflightCache: PreflightCache,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    ) async -> [String: HealthStatus] {
        let packages = CapabilityRuntimeResourceMatcher.packageDefinitions()
        let enabledPackageIDs = Set(task.workspace?.enabledCapabilityIDs ?? [])
        let resolvedScope = capabilityResolutionSnapshot.scope(.providerLaunch(contextText: contextText))
        let selectedSkillNames = Set(
            resolvedScope.behaviorSkills.map(\.name)
                .map(CapabilityRuntimeResourceMatcher.normalizedName)
        )
        var statuses: [String: HealthStatus] = [:]

        for package in packages where shouldProbePrerequisites(
            package,
            enabledPackageIDs: enabledPackageIDs,
            selectedSkillNames: selectedSkillNames
        ) {
            let packageStatuses = await CapabilityHealthService.prerequisiteStatuses(
                for: package,
                cache: preflightCache
            )
            statuses.merge(packageStatuses) { _, new in new }
        }

        return statuses
    }

    private static func shouldProbePrerequisites(
        _ package: PluginPackage,
        enabledPackageIDs: Set<String>,
        selectedSkillNames: Set<String>
    ) -> Bool {
        if enabledPackageIDs.contains(package.id) {
            return true
        }
        let packageSkillNames = Set(
            package.skills.map { CapabilityRuntimeResourceMatcher.normalizedName($0.name) }
        )
        return !packageSkillNames.isDisjoint(with: selectedSkillNames)
    }

    static func preflightCapabilitiesBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        contextText: String = "",
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        runtimeProfile: (AgentRuntimeID) -> AgentRuntimeCapabilityProfile = {
            AgentRuntimeCapabilityProfileService.profile(for: $0, executablePath: "")
        }
    ) -> Bool {
        preflightCapabilitiesBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            runtimeProfile: runtimeProfile
        ).didPass
    }

    private static func runtimeProfileProvider(
        _ configuration: AgentRuntimeConfiguration?
    ) -> (AgentRuntimeID) -> AgentRuntimeCapabilityProfile {
        guard let configuration else {
            return { runtime in
                AgentRuntimeCapabilityProfileService.profile(for: runtime, executablePath: "")
            }
        }
        return { runtime in
            let settings = AgentRuntimeAdapterRegistry.adapter(for: runtime)
                .launchSettings(configuration: configuration)
            return AgentRuntimeCapabilityProfileService.profile(
                for: runtime,
                executablePath: settings.executablePath
            )
        }
    }

    private static func runtimeReadinessFailureMessage(_ check: RuntimeReadinessCheck) -> String {
        let remediation = check.remediation.map { "\n\n\($0)" } ?? ""
        return """
        \(check.title) check failed before the agent ran:

        \(check.detail)\(remediation)
        """
    }

    private static func displayName(for connection: SSHConnection) -> String {
        let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let alias = connection.configAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty { return alias }
        return connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func remoteWorkspacePreflightMessage(
        connectionNames: [String],
        aliasNames: [String],
        runtime: AgentRuntimeID
    ) -> String {
        let connectionSummary = connectionNames.isEmpty
            ? "an SSH connection"
            : connectionNames.joined(separator: ", ")
        let aliasSummary = aliasNames.isEmpty
            ? "No SSH config alias is recorded."
            : "SSH aliases: \(aliasNames.joined(separator: ", "))."
        return """
        Remote workspace preflight: \(connectionSummary) is configured for this workspace. \(aliasSummary)

        ASTRA will launch \(runtime.rawValue) with SSH-aware filesystem access when the provider supports it so local SSH config, SSH keys, and gcloud/IAP ProxyCommand inputs remain reachable. If the remote still cannot connect, check that the VM is running and that `gcloud auth list` and `ssh <alias> "echo connected"` work in Terminal.
        """
    }

    private static func dockerImagePreflightFailure(
        for image: String,
        error: DockerImageAvailabilityError
    ) -> (
        reason: TaskRunStopReason,
        result: String,
        detail: String,
        remediation: String
    ) {
        switch error {
        case .missingImage:
            return (
                .dockerImageUnavailable,
                "image_missing",
                "Docker image \(image) is not loaded on this Mac.",
                "Build the workspace image from the Container panel, pull the image, or choose a loaded image before retrying."
            )
        case .invalidImageReference(let invalidImage):
            return (
                .dockerImageUnavailable,
                "invalid_image_reference",
                "Docker image reference \(invalidImage) is not safe to pass to Docker.",
                "Select or rebuild an image with a standard Docker image reference."
            )
        case .unsafeRemoteContext(let detail):
            return (
                .dockerContextUnapproved,
                "unsafe_remote_context",
                detail,
                "Switch Docker Desktop back to a local context, or add an explicit remote-Docker approval flow before using this context for ASTRA tasks."
            )
        case .unavailable(let detail):
            let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                .dockerDaemonUnavailable,
                "docker_unavailable",
                cleaned.isEmpty ? "Docker is not available." : cleaned,
                "Start Docker Desktop, verify `docker image inspect \(image)` works in Terminal, then retry."
            )
        }
    }

    private static func dockerImagePreflightFailureMessage(
        image: String,
        detail: String,
        remediation: String
    ) -> String {
        """
        Docker image preflight stopped this task before the agent ran:

        \(detail)

        Image: \(image)

        \(remediation)
        """
    }

    static func finishPreLaunchFailure(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        reason: String,
        payload: String
    ) {
        run.status = .failed
        run.typedStopReason = TaskRunStopReason.custom(reason)
        run.completedAt = Date()
        TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: run.completedAt ?? Date())
        let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run)
        modelContext.insert(event)
        AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
            "reason": reason
        ], level: .error)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }
}
