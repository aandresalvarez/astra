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
    }

    var status: Status
    var phase: String
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
             .connectorPreflightPassed:
            return true
        case .taskFolderCreateFailed,
             .runtimeReadinessFailed,
             .credentialProjectionFailed,
             .capabilityRuntimeResourcesMissing,
             .connectorPreflightFailed:
            return false
        }
    }
}

@MainActor
enum AgentRuntimeLaunchPreflight {
    static func prepareTaskFolderForLaunchResult(
        _ task: AgentTask,
        modelContext: ModelContext,
        phase: String
    ) -> AgentRuntimeLaunchPreflightResult {
        do {
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            let fields = [
                "event": "task_folder_prepared",
                "phase": phase,
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
                "phase": phase,
                "error_type": String(describing: type(of: error)),
                "error_description": error.localizedDescription,
                "result": AgentRuntimeLaunchPreflightResult.Status.taskFolderCreateFailed.rawValue
            ]
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: fields, level: .error)
            task.status = .failed
            let now = Date()
            task.updatedAt = now
            task.completedAt = now
            task.markUnreadForCurrentStatus(at: now)
            modelContext.insert(TaskEvent(
                task: task,
                type: "error",
                payload: "ASTRA could not create this task's output folder before launching the agent: \(error.localizedDescription)"
            ))
            try? modelContext.save()
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
        phase: String
    ) -> Bool {
        prepareTaskFolderForLaunchResult(task, modelContext: modelContext, phase: phase).didPass
    }

    static func preflightConnectorsBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        contextText: String
    ) async -> AgentRuntimeLaunchPreflightResult {
        let capabilityResult = await preflightCapabilitiesBeforeLaunchResultWithPrerequisiteChecks(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText
        )
        guard capabilityResult.didPass else {
            return capabilityResult
        }

        let fullContext = [
            task.goal,
            task.title,
            contextText
        ].joined(separator: "\n")
        let scopedConnectors = TaskCapabilityResolver(task: task).promptScope(contextText: contextText).connectors
        // Service-agnostic credential presence check. Non-blocking — the
        // agent may not need every projected connector — but a connector
        // with declared, unloadable credentials must not fail silently.
        let missingCredentials = ConnectorRuntimeProjection(connectors: scopedConnectors)
            .missingCredentialKeysByConnector()
        if !missingCredentials.isEmpty {
            var warningFields = CapabilityAudit.taskContextFields(
                source: "connector_credential_preflight",
                task: task,
                scope: .providerLaunch(contextText: contextText)
            )
            warningFields["phase"] = phase
            warningFields["result"] = "credentials_missing"
            warningFields["connector_names"] = CapabilityAudit.compactNames(missingCredentials.map(\.connector.name))
            warningFields["missing_key_names"] = missingCredentials
                .flatMap(\.missingKeys)
                .sorted()
                .joined(separator: ",")
            AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: warningFields, level: .warning, fieldMaxLength: 240)
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
        preflightFields["phase"] = phase
        preflightFields["preflight_connector_count"] = String(connectors.count)
        AppLogger.audit(.capabilityChatContext, category: "Worker", taskID: task.id, fields: preflightFields, level: .debug, fieldMaxLength: 240)

        guard let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: connectors,
            contextText: fullContext,
            workspaceID: task.workspace?.id,
            traceID: traceID
        ) else {
            let resultFields = [
                "source": "task_preflight",
                "trace_id": traceID,
                "phase": phase,
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
        fields["phase"] = phase
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

    static func preflightConnectorsBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        contextText: String
    ) async -> Bool {
        await preflightConnectorsBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText
        ).didPass
    }

    static func preflightRemoteWorkspaceBeforeLaunchResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        runtime: AgentRuntimeID
    ) -> AgentRuntimeLaunchPreflightResult {
        let buildInfo = AppBuildInfo.current
        var fields = buildInfo.auditFields
        fields.merge([
            "source": "remote_workspace_preflight",
            "phase": phase,
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
        try? modelContext.save()

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
        phase: String,
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
        phase: String,
        report: RuntimeReadinessReport
    ) -> AgentRuntimeLaunchPreflightResult {
        let blockedChecks = report.checks.filter { $0.state == .blocked }
        var fields: [String: String] = [
            "source": "runtime_readiness_preflight",
            "phase": phase,
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
        phase: String,
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
        phase: String,
        codeDirectory: String,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> AgentRuntimeLaunchPreflightResult {
        let report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: codeDirectory,
            homeDirectoryPath: homeDirectoryPath,
            fileManager: fileManager
        )
        var fields = report.auditFields
        fields["phase"] = phase
        fields["runtime"] = task.resolvedRuntimeID.rawValue
        fields["diagnostic_result"] = report.shouldBlockLaunch
            ? AgentRuntimeLaunchPreflightResult.Status.credentialProjectionFailed.rawValue
            : AgentRuntimeLaunchPreflightResult.Status.credentialProjectionPassed.rawValue
        fields["result"] = report.shouldBlockLaunch ? "blocked" : "passed"

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

    static func preflightCredentialProjectionBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
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
        phase: String,
        contextText: String = "",
        prerequisiteStatuses: [String: HealthStatus] = [:],
        mcpDetectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        mcpIsExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AgentRuntimeLaunchPreflightResult {
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
            scope: .providerLaunch(contextText: contextText)
        )
        var fields = CapabilityAudit.taskContextFields(
            source: "capability_runtime_integrity",
            task: task,
            scope: .providerLaunch(contextText: contextText)
        )
        fields.merge(AppBuildInfo.current.auditFields) { _, new in new }
        fields["phase"] = phase
        fields["result"] = issues.isEmpty ? "passed" : "missing_resources"
        for (key, value) in CapabilityRuntimeIntegrityService.summaryFields(for: issues) {
            fields[key] = value
        }

        // MCP servers are materialized only for runtimes that support them;
        // for those, a stdio server whose command can't be resolved would
        // fail opaquely mid-run, so it blocks the launch here instead.
        let runtime = AgentRuntimeID(rawValue: task.runtimeID ?? "") ?? TaskExecutionDefaults.runtime
        let mcpIssues: [MCPRuntimeProjection.PreflightIssue]
        if AgentRuntimeAdapterRegistry.descriptor(for: runtime).supportsMCPServers {
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
        phase: String,
        contextText: String = "",
        preflightCache: PreflightCache = PreflightCache()
    ) async -> AgentRuntimeLaunchPreflightResult {
        let prerequisiteStatuses = await prerequisiteStatusesBeforeLaunch(
            task: task,
            contextText: contextText,
            preflightCache: preflightCache
        )
        return preflightCapabilitiesBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText,
            prerequisiteStatuses: prerequisiteStatuses
        )
    }

    private static func prerequisiteStatusesBeforeLaunch(
        task: AgentTask,
        contextText: String,
        preflightCache: PreflightCache
    ) async -> [String: HealthStatus] {
        let packages = CapabilityRuntimeResourceMatcher.packageDefinitions()
        let enabledPackageIDs = Set(task.workspace?.enabledCapabilityIDs ?? [])
        let resolvedScope = TaskCapabilityResolver(task: task).resolvedScope(.providerLaunch(contextText: contextText))
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
        phase: String,
        contextText: String = ""
    ) -> Bool {
        preflightCapabilitiesBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText
        ).didPass
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
        task.status = .failed
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)
        let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run)
        modelContext.insert(event)
        AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
            "reason": reason
        ], level: .error)
        try? modelContext.save()
    }
}
