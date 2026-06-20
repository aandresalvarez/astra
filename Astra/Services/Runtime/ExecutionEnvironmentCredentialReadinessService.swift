import Foundation

enum ExecutionEnvironmentCredentialProjectionState: String, Sendable, Equatable {
    case notRequired = "not_required"
    case requiredButHostCredentialMissing = "required_but_host_credential_missing"
    case hostCredentialAvailableButNotProjected = "host_credential_available_but_not_projected"
    case pinnedTaskSnapshotMissingProjection = "pinned_task_snapshot_missing_projection"
    case projectedButHostCredentialMissing = "projected_but_host_credential_missing"
    case ready
    case failed
}

struct ExecutionEnvironmentCredentialReadinessReport: Sendable, Equatable {
    var state: ExecutionEnvironmentCredentialProjectionState
    var requiredProjectionIDs: [String]
    var requiredCredentialKinds: [String]
    var evidence: [String]
    var hostCredentialPath: String?
    var projectedContainerPath: String?
    var projectedEnvironmentKeys: [String]
    var isTaskSnapshotStale: Bool
    var detail: String
    var remediation: String?

    var shouldBlockLaunch: Bool {
        switch state {
        case .notRequired, .ready:
            return false
        case .requiredButHostCredentialMissing,
             .hostCredentialAvailableButNotProjected,
             .pinnedTaskSnapshotMissingProjection,
             .projectedButHostCredentialMissing,
             .failed:
            return true
        }
    }

    var userMessage: String {
        guard shouldBlockLaunch else { return detail }
        let remediationText = remediation.map { "\n\n\($0)" } ?? ""
        return """
        Container credential preflight stopped this task before the agent ran:

        \(detail)\(remediationText)
        """
    }

    var auditFields: [String: String] {
        [
            "source": "execution_environment_credential_readiness",
            "credential_projection_state": state.rawValue,
            "required_projection_ids": requiredProjectionIDs.joined(separator: ","),
            "required_credential_kinds": requiredCredentialKinds.joined(separator: ","),
            "host_credential_path": hostCredentialPath ?? "none",
            "projected_container_path": projectedContainerPath ?? "none",
            "projected_environment_keys": projectedEnvironmentKeys.joined(separator: ","),
            "task_snapshot_stale": String(isTaskSnapshotStale),
            "evidence": evidence.joined(separator: ",")
        ]
    }
}

enum ExecutionEnvironmentCredentialReadinessService {
    static func evaluate(
        task: AgentTask,
        codeDirectory: String,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> ExecutionEnvironmentCredentialReadinessReport {
        let environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        guard environment.isContainerized else {
            return ExecutionEnvironmentCredentialReadinessReport(
                state: .notRequired,
                requiredProjectionIDs: [],
                requiredCredentialKinds: [],
                evidence: [],
                hostCredentialPath: nil,
                projectedContainerPath: nil,
                projectedEnvironmentKeys: [],
                isTaskSnapshotStale: false,
                detail: "Host execution does not require Docker credential projection.",
                remediation: nil
            )
        }

        let requirement = detectCredentialRequirement(
            codeDirectory: codeDirectory,
            fileManager: fileManager
        )
        guard requirement.requiresGCPADC else {
            return ExecutionEnvironmentCredentialReadinessReport(
                state: .notRequired,
                requiredProjectionIDs: [],
                requiredCredentialKinds: [],
                evidence: requirement.evidence,
                hostCredentialPath: nil,
                projectedContainerPath: nil,
                projectedEnvironmentKeys: [],
                isTaskSnapshotStale: false,
                detail: "No container credential projection requirement was detected for this workspace.",
                remediation: nil
            )
        }

        let gcloudDirectory = ExecutionEnvironmentCredentialProjection
            .defaultGCPADCHostPath(homeDirectory: homeDirectoryPath)
        let adcFile = (gcloudDirectory as NSString)
            .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
        let hostADCExists = fileManager.fileExists(atPath: adcFile)
        let projection = environment.effectiveCredentialProjections.first {
            $0.id == ExecutionEnvironmentCredentialProjection.gcpADCID || $0.kind == .gcpADC
        }
        let projectedKeys = projection?.environment.keys.sorted() ?? []
        let taskSnapshotStale = taskSnapshotIsMissingProjectionButWorkspaceDefaultHasIt(
            task: task,
            projectionID: ExecutionEnvironmentCredentialProjection.gcpADCID
        )

        if projection == nil, taskSnapshotStale {
            return gcpReport(
                state: .pinnedTaskSnapshotMissingProjection,
                evidence: requirement.evidence,
                hostCredentialPath: adcFile,
                projectedContainerPath: nil,
                projectedEnvironmentKeys: [],
                isTaskSnapshotStale: true,
                detail: "This task is pinned to an older Docker environment snapshot without GCP Application Default Credentials, even though the workspace default now has GCP credentials connected.",
                remediation: "Fork this task or start a new task so ASTRA can capture the current Docker credential projection."
            )
        }

        guard let projection else {
            let state: ExecutionEnvironmentCredentialProjectionState = hostADCExists
                ? .hostCredentialAvailableButNotProjected
                : .requiredButHostCredentialMissing
            let detail = hostADCExists
                ? "This Docker workspace appears to use BigQuery/dbt, and local GCP Application Default Credentials exist, but they are not connected to the selected Docker environment."
                : "This Docker workspace appears to use BigQuery/dbt, but no local GCP Application Default Credentials file was found at \(adcFile)."
            let remediation = hostADCExists
                ? "Use the Container panel action “Connect GCP credentials”, then retry with a new or forked task snapshot."
                : "Run `gcloud auth application-default login` on this Mac, then connect GCP credentials in the Container panel."
            return gcpReport(
                state: state,
                evidence: requirement.evidence,
                hostCredentialPath: adcFile,
                projectedContainerPath: nil,
                projectedEnvironmentKeys: [],
                isTaskSnapshotStale: false,
                detail: detail,
                remediation: remediation
            )
        }

        let projectedADCFile = (projection.hostPath as NSString)
            .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
        guard fileManager.fileExists(atPath: projectedADCFile) else {
            return gcpReport(
                state: .projectedButHostCredentialMissing,
                evidence: requirement.evidence,
                hostCredentialPath: projectedADCFile,
                projectedContainerPath: projection.containerPath,
                projectedEnvironmentKeys: projectedKeys,
                isTaskSnapshotStale: false,
                detail: "The selected Docker environment has a GCP credential projection, but the projected Application Default Credentials file is missing at \(projectedADCFile).",
                remediation: "Reconnect GCP credentials in the Container panel after refreshing local Application Default Credentials."
            )
        }

        return gcpReport(
            state: .ready,
            evidence: requirement.evidence,
            hostCredentialPath: projectedADCFile,
            projectedContainerPath: projection.containerPath,
            projectedEnvironmentKeys: projectedKeys,
            isTaskSnapshotStale: false,
            detail: "GCP Application Default Credentials are projected into the Docker environment.",
            remediation: nil
        )
    }

    private static func gcpReport(
        state: ExecutionEnvironmentCredentialProjectionState,
        evidence: [String],
        hostCredentialPath: String?,
        projectedContainerPath: String?,
        projectedEnvironmentKeys: [String],
        isTaskSnapshotStale: Bool,
        detail: String,
        remediation: String?
    ) -> ExecutionEnvironmentCredentialReadinessReport {
        ExecutionEnvironmentCredentialReadinessReport(
            state: state,
            requiredProjectionIDs: [ExecutionEnvironmentCredentialProjection.gcpADCID],
            requiredCredentialKinds: ["gcp_adc"],
            evidence: evidence,
            hostCredentialPath: hostCredentialPath,
            projectedContainerPath: projectedContainerPath,
            projectedEnvironmentKeys: projectedEnvironmentKeys,
            isTaskSnapshotStale: isTaskSnapshotStale,
            detail: detail,
            remediation: remediation
        )
    }

    private static func taskSnapshotIsMissingProjectionButWorkspaceDefaultHasIt(
        task: AgentTask,
        projectionID: String
    ) -> Bool {
        guard let snapshot = task.executionEnvironmentSnapshotJSON,
              !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let workspaceJSON = task.workspace?.activeExecutionEnvironmentJSON,
              !workspaceJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let snapshotEnvironment = ExecutionEnvironmentStore.decode(snapshot)
        let workspaceEnvironment = ExecutionEnvironmentStore.decode(workspaceJSON)
        let snapshotHasProjection = snapshotEnvironment.effectiveCredentialProjections.contains { $0.id == projectionID }
        let workspaceHasProjection = workspaceEnvironment.effectiveCredentialProjections.contains { $0.id == projectionID }
        return !snapshotHasProjection && workspaceHasProjection
    }

    private static func detectCredentialRequirement(
        codeDirectory: String,
        fileManager: FileManager
    ) -> (requiresGCPADC: Bool, evidence: [String]) {
        let root = WorkspacePathPresentation.standardizedPath(codeDirectory)
        guard !root.isEmpty else { return (false, []) }

        var evidence: [String] = []
        let directFiles = [
            "pyproject.toml",
            "requirements.txt",
            "requirements-dev.txt",
            "requirements.lock",
            "uv.lock",
            "poetry.lock",
            "dbt_project.yml",
            "profiles.yml",
            "profiles.yaml"
        ]
        for relative in directFiles {
            appendBigQueryEvidence(
                filePath: (root as NSString).appendingPathComponent(relative),
                root: root,
                evidence: &evidence,
                fileManager: fileManager
            )
        }

        let dbtRoot = (root as NSString).appendingPathComponent("dbt")
        enumerateCandidateFiles(root: dbtRoot, fileManager: fileManager) { path in
            appendBigQueryEvidence(filePath: path, root: root, evidence: &evidence, fileManager: fileManager)
            return evidence.count < 8
        }

        return (!evidence.isEmpty, Array(evidence.prefix(8)))
    }

    private static func enumerateCandidateFiles(
        root: String,
        fileManager: FileManager,
        visit: (String) -> Bool
    ) {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        guard let enumerator = fileManager.enumerator(atPath: root) else { return }
        var visited = 0
        for case let relativePath as String in enumerator {
            visited += 1
            if visited > 1_500 { break }
            let name = (relativePath as NSString).lastPathComponent.lowercased()
            guard ["profiles.yml", "profiles.yaml", "dbt_project.yml", "packages.yml", "packages.yaml"].contains(name) else {
                continue
            }
            let fullPath = (root as NSString).appendingPathComponent(relativePath)
            if !visit(fullPath) { break }
        }
    }

    private static func appendBigQueryEvidence(
        filePath: String,
        root: String,
        evidence: inout [String],
        fileManager: FileManager
    ) {
        guard evidence.count < 8,
              fileManager.fileExists(atPath: filePath),
              let attributes = try? fileManager.attributesOfItem(atPath: filePath),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 512_000,
              let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return
        }
        let lower = content.lowercased()
        guard lower.contains("dbt-bigquery")
            || lower.contains("google-cloud-bigquery")
            || lower.contains("type: bigquery")
            || lower.contains("type:bigquery")
            || lower.contains("adapter: bigquery") else {
            return
        }
        let relative = relativePath(filePath, root: root)
        if !evidence.contains(relative) {
            evidence.append(relative)
        }
    }

    private static func relativePath(_ path: String, root: String) -> String {
        let normalizedPath = WorkspacePathPresentation.standardizedPath(path)
        let normalizedRoot = WorkspacePathPresentation.standardizedPath(root)
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else { return normalizedPath }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }
}
