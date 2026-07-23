import Foundation
import SwiftUI
import ASTRACore
import ASTRAModels

struct DockerEnvironmentOption: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var iconSystemName: String
    var help: String
    var isSelected: Bool
    var isEnabled: Bool
    var environment: WorkspaceExecutionEnvironment
}

struct DockerRuntimeContractRow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var iconSystemName: String
    var help: String
}

@MainActor
final class WorkspaceDockerViewModel: ObservableObject {
    @Published var candidates: [DockerWorkspaceCandidate] = []
    @Published var selectedEnvironment: WorkspaceExecutionEnvironment = .host
    @Published var isRefreshing = false
    @Published var isBuildingImage = false
    @Published private(set) var imageInventoryError: DockerImageInventoryError?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private var workspace: Workspace?
    private var selectedTask: AgentTask?
    private let imageInventory: any DockerImageInventoryListing
    private let imageReadiness: any DockerImageReadinessChecking
    private let imageBuilder: any DockerImageBuilding
    private let fileManager: FileManager
    private let homeDirectoryPath: String

    init(
        imageBuilder: any DockerImageBuilding = DockerImageBuildService(),
        fileManager: FileManager = .default,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.imageInventory = DockerImageInventoryService()
        self.imageReadiness = DockerImageReadinessService()
        self.imageBuilder = imageBuilder
        self.fileManager = fileManager
        self.homeDirectoryPath = WorkspacePathPresentation.standardizedPath(homeDirectoryPath)
    }

    /// Dependency-injection initializer. Tests that supply a synthetic image
    /// inventory may omit a readiness checker because those fixtures already
    /// define their listed images as authoritative; production always uses the
    /// launch-equivalent `DockerImageReadinessService` above.
    init(
        imageInventory: any DockerImageInventoryListing,
        imageReadiness: any DockerImageReadinessChecking = ListedImageReadinessChecker(),
        imageBuilder: any DockerImageBuilding = DockerImageBuildService(),
        fileManager: FileManager = .default,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.imageInventory = imageInventory
        self.imageReadiness = imageReadiness
        self.imageBuilder = imageBuilder
        self.fileManager = fileManager
        self.homeDirectoryPath = WorkspacePathPresentation.standardizedPath(homeDirectoryPath)
    }

    func setup(for workspace: Workspace, selectedTask: AgentTask? = nil) {
        self.workspace = workspace
        self.selectedTask = selectedTask
        syncSelectedEnvironment()
        Task { await refresh() }
    }

    #if DEBUG
    func setWorkspaceForTesting(_ workspace: Workspace, selectedTask: AgentTask? = nil) {
        self.workspace = workspace
        self.selectedTask = selectedTask
        syncSelectedEnvironment()
    }
    #endif

    func refresh() async {
        guard let workspace else { return }
        isRefreshing = true
        statusMessage = nil
        defer { isRefreshing = false }

        let discovered = DockerWorkspaceDiscoveryService.candidates(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        let loadedImages = await imageInventory.listLoadedImages()
        var next = discovered
        switch loadedImages {
        case .success(let images):
            imageInventoryError = nil
            let discoveredImages = imageCandidates(for: workspace, images: images)
            next.append(contentsOf: await Self.validateImageCandidates(
                discoveredImages,
                readiness: imageReadiness
            ))
        case .failure(let error):
            imageInventoryError = error
        }

        candidates = Self.deduplicated(next)
        syncSelectedEnvironment()
    }

    var shouldShowSection: Bool {
        selectedEnvironment.isContainerized || !candidates.isEmpty
    }

    var runnableCandidates: [DockerWorkspaceCandidate] {
        candidates.filter(\.isRunnable)
    }

    var dockerfileCandidate: DockerWorkspaceCandidate? {
        candidates.first { $0.environment.kind == .dockerfile }
    }

    var environmentOptions: [DockerEnvironmentOption] {
        var options = [
            environmentOption(for: .host, isEnabled: canSelectEnvironmentOption)
        ]
        options.append(contentsOf: runnableCandidates.map {
            environmentOption(for: $0.environment, isEnabled: canSelectEnvironmentOption)
        })

        if selectedEnvironment.isContainerized,
           !options.contains(where: { $0.environment.id == selectedEnvironment.id }) {
            options.insert(environmentOption(
                for: selectedEnvironment,
                isEnabled: false,
                subtitleOverride: "\(selectedSubtitle) unavailable in Docker inventory"
            ), at: min(1, options.count))
        }
        return options
    }

    var canChangeActiveEnvironment: Bool {
        guard let task = selectedTask else { return true }
        return task.status == .draft
    }

    var canUseEnvironmentPicker: Bool {
        canChangeActiveEnvironment || canRepinPinnedTaskEnvironment
    }

    var canRepinPinnedTaskEnvironment: Bool {
        guard let task = selectedTask,
              task.status != .draft || !task.runs.isEmpty else {
            return false
        }
        return pinnedTaskEnvironmentTargets.contains {
            $0.signatureFingerprint != selectedEnvironment.signatureFingerprint
        }
    }

    private var canSelectEnvironmentOption: Bool {
        canChangeActiveEnvironment || canRepinPinnedTaskEnvironment
    }

    var canRepairCredentialProjection: Bool {
        guard let task = selectedTask,
              !canChangeActiveEnvironment,
              !task.runs.isEmpty else {
            return false
        }
        return task.runs.allSatisfy(Self.isCredentialProjectionSetupFailure)
    }

    var canUpdatePinnedTaskCredentialProjection: Bool {
        guard selectedTask != nil,
              !canChangeActiveEnvironment,
              selectedEnvironment.isContainerized,
              gcpADCCredentialFileExists,
              let report = credentialReadinessReport,
              report.shouldBlockLaunch,
              report.requiredProjectionIDs.contains(ExecutionEnvironmentCredentialProjection.gcpADCID) else {
            return false
        }
        switch report.state {
        case .hostCredentialAvailableButNotProjected,
             .pinnedTaskSnapshotMissingProjection,
             .projectedButHostCredentialMissing:
            return true
        case .notRequired,
             .requiredButHostCredentialMissing,
             .ready,
             .failed:
            return false
        }
    }

    var canSwitchPinnedTaskToWorkspaceEnvironment: Bool {
        guard let task = selectedTask,
              !canChangeActiveEnvironment,
              task.status != .draft,
              let workspaceEnvironment = workspaceDefaultEnvironment,
              workspaceEnvironment.isContainerized else {
            return false
        }
        return selectedEnvironment.signatureFingerprint != workspaceEnvironment.signatureFingerprint
    }

    var pinnedTaskEnvironmentActionTitle: String {
        guard let environment = workspaceDefaultEnvironment else {
            return "Use workspace container"
        }
        return "Retry in \(environment.displayName)"
    }

    var pinnedTaskEnvironmentActionSubtitle: String {
        guard let environment = workspaceDefaultEnvironment else {
            return "Switch the next retry to the workspace default container."
        }
        if let image = environment.image {
            return "Next retry will run project commands in \(image)."
        }
        return "Next retry will use the workspace default container."
    }

    var pinnedTaskEnvironmentActionHelp: String {
        guard let environment = workspaceDefaultEnvironment else {
            return pinnedTaskEnvironmentActionSubtitle
        }
        let effect = selectedEnvironmentEffect(for: environment)
        return "This changes only this task's next run snapshot. Earlier run manifests stay unchanged. \(effect)"
    }

    var activeScopeLabel: String {
        guard let task = selectedTask else { return "Workspace default" }
        return task.status == .draft ? "Draft task" : "Pinned task"
    }

    var selectedTitle: String {
        selectedEnvironment.isHost ? "Host" : selectedEnvironment.displayName
    }

    var selectedSubtitle: String {
        if selectedEnvironment.isHost {
            return "Runs directly on macOS"
        }
        if let image = selectedEnvironment.image {
            if selectedEnvironment.workspaceCommandsRunInsideContainer {
                return "Commands run in image \(image)"
            }
            return "Provider runs in image \(image)"
        }
        return selectedEnvironment.kind.rawValue
    }

    var environmentPickerTitle: String {
        guard let task = selectedTask else { return "Run new tasks in" }
        return task.status == .draft ? "Run this draft in" : "Pinned to"
    }

    var environmentPickerSubtitle: String {
        if selectedEnvironment.isHost {
            return "Host - providers run directly on macOS"
        }
        if let image = selectedEnvironment.image {
            if selectedEnvironment.workspaceCommandsRunInsideContainer {
                return "\(selectedEnvironment.displayName) - commands in \(image)"
            }
            return "\(selectedEnvironment.displayName) - provider in \(image)"
        }
        return "\(selectedEnvironment.displayName) - \(selectedEnvironment.kind.rawValue)"
    }

    var environmentPickerHelp: String {
        if canRepinPinnedTaskEnvironment {
            let effect = selectedEnvironmentEffect(for: selectedEnvironment)
            return "Pinned task. Changing this updates only this task's next retry snapshot. Earlier run manifests keep their recorded environment. \(effect)"
        }
        if !canChangeActiveEnvironment {
            return "Pinned task. This task keeps \(selectedTitle) because it already has execution history, and no alternate loaded Docker image is available yet. Build or load an image, then select it here for the next retry."
        }

        let scope = selectedTask == nil
            ? "Changing this sets the workspace default for new tasks. Existing tasks and runs keep their pinned environment."
            : "Changing this sets only this draft task. The workspace default is unchanged."
        let effect = selectedEnvironmentEffect(for: selectedEnvironment)
        return "\(scope) \(effect)"
    }

    var runtimeContractRows: [DockerRuntimeContractRow] {
        if selectedEnvironment.isHost {
            return [
                DockerRuntimeContractRow(
                    id: "provider",
                    title: "Provider: Host",
                    subtitle: "AI provider CLI runs on macOS.",
                    iconSystemName: "cpu",
                    help: "ASTRA launches the selected AI provider directly on this Mac."
                ),
                DockerRuntimeContractRow(
                    id: "workspace-commands",
                    title: "Workspace commands: Host",
                    subtitle: "Project shell commands run on macOS.",
                    iconSystemName: "terminal",
                    help: "Provider shell tools execute against the host workspace and ASTRA's macOS sandbox grants."
                )
            ]
        }

        let image = selectedEnvironment.image ?? selectedEnvironment.displayName
        var rows = [
            DockerRuntimeContractRow(
                id: "provider",
                title: "Provider: Host",
                subtitle: "AI provider stays on macOS.",
                iconSystemName: "cpu",
                help: "ASTRA keeps provider CLIs on the host so provider authentication, browser bridges, and control-plane capabilities are managed by ASTRA instead of being baked into the image."
            ),
            DockerRuntimeContractRow(
                id: "workspace-commands",
                title: "Workspace commands: Docker image",
                subtitle: "Project shell runs in \(image).",
                iconSystemName: "shippingbox.fill",
                help: "workspace_shell and workspace_job_start execute inside the selected Docker image using mounted workspace paths such as /workspace."
            ),
            DockerRuntimeContractRow(
                id: "host-capabilities",
                title: "Host capabilities: ASTRA managed",
                subtitle: "GitHub, Jira, GCloud, SSH, browser, and Keychain stay outside workspace_shell.",
                iconSystemName: "link.circle",
                help: "Control-plane work must use enabled ASTRA capabilities. The Docker workspace shell is only for project commands inside the image."
            )
        ]
        if shouldShowCredentialProjectionRow {
            rows.append(DockerRuntimeContractRow(
                id: "gcp-credentials",
                title: credentialProjectionTitle,
                subtitle: credentialProjectionSubtitle,
                iconSystemName: "key.fill",
                help: credentialProjectionHelp
            ))
        }
        return rows
    }

    var dockerIssueTitle: String? {
        if unavailableImageCandidate != nil {
            return "Docker image is not runnable"
        }
        switch imageInventoryError {
        case .cliMissing:
            return "Docker CLI was not found"
        case .unavailable:
            return "Docker is not connected"
        case .unsafeRemoteContext:
            return "Docker context needs approval"
        case nil:
            return nil
        }
    }

    var dockerIssueSubtitle: String? {
        if let candidate = unavailableImageCandidate {
            return candidate.issue ?? "Docker cannot resolve the selected image reference."
        }
        switch imageInventoryError {
        case .cliMissing:
            return "Install or reopen Docker Desktop, then refresh."
        case .unavailable:
            return "Start Docker Desktop, then refresh."
        case .unsafeRemoteContext:
            return "Switch to a local Docker context and unset DOCKER_HOST, then refresh."
        case nil:
            return nil
        }
    }

    var imageInventoryIssue: String? {
        unavailableImageCandidate?.issue ?? imageInventoryError?.localizedDescription
    }

    private var unavailableImageCandidate: DockerWorkspaceCandidate? {
        let unavailable = candidates.filter { $0.environment.kind == .dockerImage && !$0.isRunnable }
        if let selected = unavailable.first(where: { isSelected($0) }) { return selected }
        return runnableCandidates.contains(where: { $0.environment.kind == .dockerImage }) ? nil : unavailable.first
    }

    var buildCommand: String? {
        guard let request = buildRequest else { return nil }
        return "docker build -t \(request.image) -f \(shellQuote(request.dockerfilePath)) \(shellQuote(request.sourcePath))"
    }

    var buildRequest: DockerImageBuildRequest? {
        guard let candidate = dockerfileCandidate,
              let dockerfilePath = candidate.environment.dockerfilePath,
              let sourcePath = candidate.environment.sourcePath,
              let image = candidate.environment.image else {
            return nil
        }
        return DockerImageBuildRequest(
            image: imageWithDefaultTag(image),
            dockerfilePath: dockerfilePath,
            sourcePath: sourcePath
        )
    }

    var setupActionTitle: String {
        if isBuildingImage { return "Building workspace image" }
        return runnableCandidates.isEmpty ? "Build workspace image" : "Build another image"
    }

    var setupActionSubtitle: String {
        guard let request = buildRequest else {
            return "Load or build a Docker image that matches this workspace."
        }
        if isBuildingImage {
            return "Docker is building \(request.image)."
        }
        return "Build \(request.image) from this workspace Dockerfile."
    }

    var setupActionHelp: String {
        buildCommand ?? setupActionSubtitle
    }

    var shouldShowCredentialProjectionRow: Bool {
        selectedEnvironment.isContainerized
    }

    var credentialProjectionTitle: String {
        if let report = credentialReadinessReport {
            switch report.state {
            case .ready:
                return "GCP credentials ready"
            case .requiredButHostCredentialMissing:
                return "GCP credentials missing"
            case .hostCredentialAvailableButNotProjected:
                if canUpdatePinnedTaskCredentialProjection {
                    return "Connect task GCP credentials"
                }
                return "Connect GCP credentials"
            case .pinnedTaskSnapshotMissingProjection:
                return (canRepairCredentialProjection || canUpdatePinnedTaskCredentialProjection)
                    ? "Update task credentials"
                    : "Task missing GCP credentials"
            case .projectedButHostCredentialMissing:
                return "GCP credentials need refresh"
            case .failed:
                return "GCP credentials need review"
            case .notRequired:
                break
            }
        }
        if hasGCPADCProjection {
            return "GCP credentials connected"
        }
        if gcpADCCredentialFileExists {
            return "Connect GCP credentials"
        }
        return "GCP credentials not found"
    }

    var credentialProjectionSubtitle: String {
        if let report = credentialReadinessReport, report.state != .notRequired {
            switch report.state {
            case .ready:
                return "Application Default Credentials are projected read-only for Docker commands."
            case .hostCredentialAvailableButNotProjected:
                if canRepairCredentialProjection || canUpdatePinnedTaskCredentialProjection {
                    return "BigQuery/dbt detected. Connect ADC to this task's next retry, then retry."
                }
                return "BigQuery/dbt detected. Connect local ADC before running container tasks."
            case .pinnedTaskSnapshotMissingProjection:
                if canRepairCredentialProjection || canUpdatePinnedTaskCredentialProjection {
                    return "Workspace credentials changed. Update this task's next retry, then retry."
                }
                return "Workspace credentials changed; fork or start a new task to use them."
            case .requiredButHostCredentialMissing:
                return "BigQuery/dbt detected, but no local ADC file was found on this Mac."
            case .projectedButHostCredentialMissing:
                return "The configured ADC projection points to a missing file."
            case .failed:
                return report.detail
            case .notRequired:
                break
            }
        }
        if hasGCPADCProjection {
            return "Application Default Credentials are mounted read-only for container commands."
        }
        if gcpADCCredentialFileExists {
            return "Use local Application Default Credentials in container commands."
        }
        return "No Application Default Credentials file was found on this Mac."
    }

    var credentialProjectionActionSystemName: String {
        if credentialReadinessReport?.state == .pinnedTaskSnapshotMissingProjection {
            return "exclamationmark.triangle.fill"
        }
        if !canChangeActiveEnvironment && hasGCPADCProjection {
            return "checkmark.circle.fill"
        }
        return hasGCPADCProjection ? "minus.circle.fill" : "link.circle.fill"
    }

    var credentialProjectionIsEnabled: Bool {
        if canChangeActiveEnvironment {
            return hasGCPADCProjection || gcpADCCredentialFileExists
        }
        if hasGCPADCProjection,
           credentialReadinessReport?.state != .projectedButHostCredentialMissing {
            return false
        }
        return (canRepairCredentialProjection || canUpdatePinnedTaskCredentialProjection)
            && gcpADCCredentialFileExists
    }

    var credentialProjectionHelp: String {
        if let report = credentialReadinessReport, report.shouldBlockLaunch {
            if canRepairCredentialProjection {
                return "\(report.detail) Connect local GCP Application Default Credentials to this setup-only failed task, then retry it."
            }
            if canUpdatePinnedTaskCredentialProjection {
                return "\(report.detail) Connect local GCP Application Default Credentials to this pinned task's next retry snapshot. Earlier run manifests stay unchanged."
            }
            let remediation = report.remediation.map { " \($0)" } ?? ""
            return "\(report.detail)\(remediation)"
        }
        if !canChangeActiveEnvironment {
            if canRepairCredentialProjection {
                if hasGCPADCProjection {
                    return "This task snapshot has local GCP Application Default Credentials projected. Retry the task so ASTRA can run Docker workspace commands with those credentials."
                }
                return "This task only failed during Docker credential setup. ASTRA can connect local GCP Application Default Credentials to this task snapshot so retry uses the repaired environment."
            }
            return "Pinned task. This task keeps its current Docker credential projection because it already has execution history."
        }
        if hasGCPADCProjection {
            return "Disconnect local GCP Application Default Credentials from this Docker environment. New workspace command containers will stop mounting \(gcpADCHostPath)."
        }
        if gcpADCCredentialFileExists {
            return "Connect local GCP Application Default Credentials. ASTRA will mount \(gcpADCHostPath) read-only at \(ExecutionEnvironmentCredentialProjection.gcpADCContainerPath), set CLOUDSDK_CONFIG and GOOGLE_APPLICATION_CREDENTIALS, keep the AI provider on macOS, and let only Docker workspace commands use those credentials."
        }
        return "No Application Default Credentials file was found at \(gcpADCCredentialFilePath)."
    }

    var detectedSummary: String? {
        let names = candidates.filter { candidate in
            !candidate.isRunnable && candidate.environment.kind != .dockerfile
        }.map { candidate in
            switch candidate.environment.kind {
            case .dockerfile: "Dockerfile"
            case .dockerCompose: "Compose"
            case .devcontainer: "Dev Container"
            case .dockerImage: "Image"
            case .dockerContainer: "Container"
            case .host: "Host"
            }
        }
        guard !names.isEmpty else { return nil }
        return "Detected \(names.joined(separator: ", "))"
    }

    func isSelected(_ candidate: DockerWorkspaceCandidate) -> Bool {
        selectedEnvironment.id == candidate.environment.id
    }

    func selectHost() {
        persist(.host)
    }

    func selectCandidate(_ candidate: DockerWorkspaceCandidate) {
        guard candidate.isRunnable else {
            errorMessage = candidate.issue ?? "This container source is discovered but not runnable yet."
            return
        }
        persist(candidate.environment)
    }

    func selectEnvironmentOption(_ optionID: String) {
        guard let option = environmentOptions.first(where: { $0.id == optionID }) else { return }
        guard option.isEnabled else {
            errorMessage = "No alternate loaded Docker environment is available for this pinned task yet."
            return
        }
        persist(option.environment)
    }

    func switchPinnedTaskToWorkspaceEnvironment() {
        guard canSwitchPinnedTaskToWorkspaceEnvironment,
              let selectedTask,
              let workspaceEnvironment = workspaceDefaultEnvironment else {
            errorMessage = "No newer workspace Docker environment is available for this pinned task."
            return
        }
        let json = ExecutionEnvironmentStore.encodeSnapshot(workspaceEnvironment)
        selectedTask.executionEnvironmentSnapshotJSON = json
        selectedTask.updatedAt = Date()
        selectedEnvironment = workspaceEnvironment
        errorMessage = nil
        statusMessage = "Next retry will use \(workspaceEnvironment.displayName)"
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
            "result": "pinned_task_environment_updated",
            "environment": workspaceEnvironment.kind.rawValue,
            "environment_id": workspaceEnvironment.id,
            "scope": activeScopeLabel,
            "task_id": selectedTask.id.uuidString
        ])
    }

    func toggleGCPADCProjection() {
        guard selectedEnvironment.isContainerized else { return }
        let canPatchPinnedTask = canRepairCredentialProjection || canUpdatePinnedTaskCredentialProjection
        guard canChangeActiveEnvironment || canPatchPinnedTask else {
            errorMessage = "This task already has execution history, and no required Docker credential update is available for its next retry."
            return
        }

        var environment = selectedEnvironment
        var projections = environment.effectiveCredentialProjections
        if hasGCPADCProjection,
           credentialReadinessReport?.state != .projectedButHostCredentialMissing {
            guard canChangeActiveEnvironment else {
                errorMessage = nil
                statusMessage = "GCP credentials are connected. Retry this task."
                return
            }
            projections.removeAll { $0.id == ExecutionEnvironmentCredentialProjection.gcpADCID }
            environment.setCredentialProjections(projections)
            persist(environment)
            statusMessage = "GCP credentials disconnected"
            return
        }

        guard gcpADCCredentialFileExists else {
            errorMessage = "GCP Application Default Credentials were not found on this Mac."
            return
        }
        projections.removeAll { $0.id == ExecutionEnvironmentCredentialProjection.gcpADCID }
        projections.append(ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcpADCHostPath))
        environment.setCredentialProjections(projections)
        if canPatchPinnedTask, !canChangeActiveEnvironment {
            updatePinnedTaskCredentialProjection(environment, alsoUpdateWorkspaceDefault: canRepairCredentialProjection)
            statusMessage = "GCP credentials connected. Retry this task."
        } else {
            persist(environment)
            statusMessage = "GCP credentials connected"
        }
    }

    func buildWorkspaceImage() async {
        guard let request = buildRequest, !isBuildingImage else { return }
        isBuildingImage = true
        errorMessage = nil
        statusMessage = "Building \(request.image)"
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
            "result": "build_started",
            "image": request.image,
            "dockerfile": request.dockerfilePath
        ], level: .info)
        defer { isBuildingImage = false }

        switch await imageBuilder.buildImage(request) {
        case .success(let summary):
            AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
                "result": "build_succeeded",
                "image": summary.image
            ], level: .info)
            await refresh()
            if let candidate = candidates.first(where: { $0.environment.image == summary.image }),
               canChangeActiveEnvironment {
                selectCandidate(candidate)
                statusMessage = "Image built and selected"
            } else if canChangeActiveEnvironment {
                statusMessage = "Image built. Refresh containers to select it."
            } else {
                statusMessage = "Image built. Select it under Pinned to for the next retry."
            }
        case .failure(let error):
            let detail = error.localizedDescription
            errorMessage = detail
            statusMessage = nil
            switch error {
            case .cliMissing:
                imageInventoryError = .cliMissing
            case .unavailable(let rawDetail):
                imageInventoryError = .unavailable(rawDetail)
            case .unsafeRemoteContext(let detail):
                imageInventoryError = .unsafeRemoteContext(detail)
            case .failed, .timedOut, .cancelled, .launchFailed:
                break
            }
            AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
                "result": "build_failed",
                "image": request.image,
                "detail": detail
            ], level: .error)
        }
    }

    func subtitle(for candidate: DockerWorkspaceCandidate) -> String {
        switch candidate.environment.kind {
        case .dockerImage:
            return candidate.environment.image.map {
                candidate.environment.workspaceCommandsRunInsideContainer
                    ? "Run project commands in \($0)"
                    : "Run provider inside \($0)"
            } ?? "Loaded Docker image"
        case .dockerfile:
            return candidate.issue ?? "Dockerfile discovered"
        case .dockerCompose:
            return candidate.issue ?? "Compose file discovered"
        case .devcontainer:
            return candidate.issue ?? "Dev container discovered"
        case .dockerContainer:
            return candidate.environment.containerName.map { "Container \($0)" } ?? "Docker container"
        case .host:
            return "Runs directly on macOS"
        }
    }

    private func persist(_ environment: WorkspaceExecutionEnvironment) {
        let isPinnedTaskRetarget = selectedTask != nil && !canChangeActiveEnvironment
        guard canChangeActiveEnvironment || canRepinPinnedTaskEnvironment else {
            errorMessage = "This pinned task has no alternate loaded Docker environment yet. Build or load an image first."
            AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
                "result": "blocked",
                "environment": environment.kind.rawValue,
                "scope": activeScopeLabel
            ], level: .warning)
            return
        }

        let json = isPinnedTaskRetarget
            ? ExecutionEnvironmentStore.encodeSnapshot(environment)
            : ExecutionEnvironmentStore.encode(environment)
        if let selectedTask {
            guard selectedTask.executionEnvironmentSnapshotJSON != json else {
                selectedEnvironment = environment
                return
            }
            selectedTask.executionEnvironmentSnapshotJSON = json
            selectedTask.updatedAt = Date()
        } else if let workspace {
            guard workspace.activeExecutionEnvironmentJSON != json else {
                selectedEnvironment = environment
                return
            }
            workspace.activeExecutionEnvironmentJSON = json
            workspace.updatedAt = Date()
        }
        selectedEnvironment = environment
        errorMessage = nil
        if isPinnedTaskRetarget {
            statusMessage = "Next retry will use \(environment.isHost ? "Host" : environment.displayName)"
        }
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
            "result": isPinnedTaskRetarget ? "pinned_task_environment_updated" : "changed",
            "environment": environment.kind.rawValue,
            "environment_id": environment.id,
            "scope": activeScopeLabel
        ])
    }

    private func updatePinnedTaskCredentialProjection(
        _ environment: WorkspaceExecutionEnvironment,
        alsoUpdateWorkspaceDefault: Bool
    ) {
        guard selectedTask != nil,
              !canChangeActiveEnvironment,
              let selectedTask else {
            persist(environment)
            return
        }

        let json = ExecutionEnvironmentStore.encodeSnapshot(environment)
        selectedTask.executionEnvironmentSnapshotJSON = json
        selectedTask.updatedAt = Date()

        if alsoUpdateWorkspaceDefault, let workspace {
            let workspaceEnvironment = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
            if workspaceEnvironment.id == environment.id {
                workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(environment)
                workspace.updatedAt = Date()
            }
        }

        selectedEnvironment = environment
        errorMessage = nil
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
            "result": alsoUpdateWorkspaceDefault
                ? "credential_projection_repaired"
                : "pinned_task_credential_projection_updated",
            "environment": environment.kind.rawValue,
            "environment_id": environment.id,
            "scope": activeScopeLabel,
            "task_id": selectedTask.id.uuidString
        ])
    }

    private func syncSelectedEnvironment() {
        if let selectedTask,
           let snapshot = selectedTask.executionEnvironmentSnapshotJSON,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedEnvironment = ExecutionEnvironmentStore.decode(snapshot)
            return
        }
        if let selectedTask, selectedTask.status != .draft || !selectedTask.runs.isEmpty {
            selectedEnvironment = .host
            return
        }
        if let workspace {
            selectedEnvironment = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        } else {
            selectedEnvironment = .host
        }
    }

    private func imageCandidates(
        for workspace: Workspace,
        images: [DockerImageReference]
    ) -> [DockerWorkspaceCandidate] {
        WorkspacePathPresentation.descriptors(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        .flatMap { descriptor -> [DockerWorkspaceCandidate] in
            let expectedRepository = DockerWorkspaceDiscoveryService.generatedImageName(for: descriptor.path)
            return images
                .filter { $0.repository == expectedRepository }
                .map { image in
                    DockerWorkspaceCandidate(
                        environment: WorkspaceExecutionEnvironment(
                            id: "image:\(image.name)",
                            kind: .dockerImage,
                            displayName: "\(descriptor.title) Image",
                            sourcePath: descriptor.path,
                            image: image.name,
                            imageDigest: image.imageID
                        ),
                        isRunnable: true,
                        issue: nil
                    )
                }
        }
    }

    nonisolated static let maxConcurrentReadinessChecks = 4

    static func validateImageCandidates(
        _ candidates: [DockerWorkspaceCandidate],
        readiness: any DockerImageReadinessChecking
    ) async -> [DockerWorkspaceCandidate] {
        await Task.detached(priority: .utility) {
            await withTaskGroup(of: (Int, DockerWorkspaceCandidate).self, returning: [DockerWorkspaceCandidate].self) { group in
                var nextIndex = 0
                var results: [(Int, DockerWorkspaceCandidate)] = []

                func addNextCandidate() {
                    guard nextIndex < candidates.count else { return }
                    let index = nextIndex
                    nextIndex += 1
                    let candidate = candidates[index]
                    group.addTask {
                        guard let image = candidate.environment.image else {
                            return (index, candidate)
                        }
                        let report = await readiness.checkImageReadiness(image)
                        var validated = candidate
                        validated.isRunnable = report.isRunnable
                        validated.issue = report.isRunnable ? nil : report.detail
                        return (index, validated)
                    }
                }

                for _ in 0..<min(maxConcurrentReadinessChecks, candidates.count) {
                    addNextCandidate()
                }
                for await result in group {
                    results.append(result)
                    addNextCandidate()
                }
                return results
                    .sorted { $0.0 < $1.0 }
                    .map(\.1)
            }
        }.value
    }

    private static func deduplicated(_ candidates: [DockerWorkspaceCandidate]) -> [DockerWorkspaceCandidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            guard !seen.contains(candidate.id) else { return false }
            seen.insert(candidate.id)
            return true
        }
    }

    private static func isCredentialProjectionSetupFailure(_ run: TaskRun) -> Bool {
        run.typedStopReason == .credentialProjectionRequired
            && run.inputTokens == 0
            && run.outputTokens == 0
            && run.tokensUsed == 0
            && run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && run.fileChanges.isEmpty
    }

    private func imageWithDefaultTag(_ image: String) -> String {
        let name = image.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        return lastComponent.contains(":") ? name : "\(name):latest"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func environmentOption(
        for environment: WorkspaceExecutionEnvironment,
        isEnabled: Bool,
        subtitleOverride: String? = nil
    ) -> DockerEnvironmentOption {
        DockerEnvironmentOption(
            id: environment.id,
            title: environment.isHost ? "Host" : environment.displayName,
            subtitle: subtitleOverride ?? environmentOptionSubtitle(for: environment),
            iconSystemName: environment.isHost ? "desktopcomputer" : "shippingbox.fill",
            help: environmentOptionHelp(for: environment),
            isSelected: selectedEnvironment.id == environment.id,
            isEnabled: isEnabled,
            environment: environment
        )
    }

    private func environmentOptionSubtitle(for environment: WorkspaceExecutionEnvironment) -> String {
        if environment.isHost {
            return "Run providers directly on macOS"
        }
        if let image = environment.image {
            if environment.workspaceCommandsRunInsideContainer {
                return "Run project commands inside image \(image)"
            }
            return "Run provider inside image \(image)"
        }
        return "Run providers through \(environment.kind.rawValue)"
    }

    private func environmentOptionHelp(for environment: WorkspaceExecutionEnvironment) -> String {
        let scope: String
        if selectedTask == nil {
            scope = "Select this to set the workspace default for new tasks."
        } else if canChangeActiveEnvironment {
            scope = "Select this to set the execution environment for this draft task."
        } else {
            scope = "Select this to change only this pinned task's next retry. Previous run manifests stay unchanged."
        }
        return "\(scope) \(selectedEnvironmentEffect(for: environment))"
    }

    private func selectedEnvironmentEffect(for environment: WorkspaceExecutionEnvironment) -> String {
        if environment.isHost {
            return "ASTRA will launch provider CLIs directly on macOS."
        }
        if let image = environment.image {
            if environment.workspaceCommandsRunInsideContainer {
                return "ASTRA will keep the AI provider on macOS and route project shell commands through Docker image \(image)."
            }
            return "ASTRA will launch provider CLIs with docker run using \(image), mount the workspace into the container, and record that environment on the task."
        }
        return "ASTRA will use the selected container environment when launching provider CLIs."
    }

    private var hasGCPADCProjection: Bool {
        selectedEnvironment.effectiveCredentialProjections.contains {
            $0.id == ExecutionEnvironmentCredentialProjection.gcpADCID
        }
    }

    private var workspaceDefaultEnvironment: WorkspaceExecutionEnvironment? {
        guard let workspace else { return nil }
        return ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
    }

    private var pinnedTaskEnvironmentTargets: [WorkspaceExecutionEnvironment] {
        var targets: [WorkspaceExecutionEnvironment] = [.host]
        targets.append(contentsOf: runnableCandidates.map(\.environment))
        if let workspaceDefaultEnvironment,
           workspaceDefaultEnvironment.isContainerized,
           !targets.contains(where: { $0.id == workspaceDefaultEnvironment.id }) {
            targets.append(workspaceDefaultEnvironment)
        }
        return targets
    }

    private var credentialReadinessReport: ExecutionEnvironmentCredentialReadinessReport? {
        guard selectedEnvironment.isContainerized,
              let workspace else {
            return nil
        }
        let task: AgentTask
        if let selectedTask {
            task = selectedTask
        } else {
            task = AgentTask(title: "Credential readiness", goal: "Evaluate Docker credentials", workspace: workspace)
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(selectedEnvironment)
        }
        let codeDirectory = selectedEnvironment.sourcePath
            ?? workspace.activeWorkingPath
            ?? workspace.primaryPath
        return ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: codeDirectory,
            homeDirectoryPath: homeDirectoryPath,
            fileManager: fileManager
        )
    }

    private var gcpADCHostPath: String {
        ExecutionEnvironmentCredentialProjection.defaultGCPADCHostPath(homeDirectory: homeDirectoryPath)
    }

    private var gcpADCCredentialFilePath: String {
        (gcpADCHostPath as NSString)
            .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
    }

    private var gcpADCCredentialFileExists: Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: gcpADCCredentialFilePath, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

private struct ListedImageReadinessChecker: DockerImageReadinessChecking {
    func checkImageReadiness(_ image: String) async -> DockerImageReadiness {
        DockerImageReadiness(
            image: image,
            state: .ready,
            imageID: nil,
            detail: "Synthetic inventory marks this image as ready."
        )
    }
}
