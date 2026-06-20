import Foundation
import SwiftUI

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

@MainActor
final class WorkspaceDockerViewModel: ObservableObject {
    @Published var candidates: [DockerWorkspaceCandidate] = []
    @Published var selectedEnvironment: WorkspaceExecutionEnvironment = .host
    @Published var isRefreshing = false
    @Published var isBuildingImage = false
    @Published var imageInventoryIssue: String?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private var workspace: Workspace?
    private var selectedTask: AgentTask?
    private let imageInventory: any DockerImageInventoryListing
    private let imageBuilder: any DockerImageBuilding
    private let fileManager: FileManager
    private let homeDirectoryPath: String

    init(
        imageInventory: any DockerImageInventoryListing = DockerImageInventoryService(),
        imageBuilder: any DockerImageBuilding = DockerImageBuildService(),
        fileManager: FileManager = .default,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.imageInventory = imageInventory
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
            imageInventoryIssue = nil
            next.append(contentsOf: imageCandidates(for: workspace, images: images))
        case .failure(let error):
            imageInventoryIssue = error.localizedDescription
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
            environmentOption(for: .host, isEnabled: canChangeActiveEnvironment)
        ]
        options.append(contentsOf: runnableCandidates.map {
            environmentOption(for: $0.environment, isEnabled: canChangeActiveEnvironment)
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
        if !canChangeActiveEnvironment {
            return "Pinned task. This task keeps \(selectedTitle) because it already has execution history. Start a new task or fork this one to use another environment."
        }

        let scope = selectedTask == nil
            ? "Changing this sets the workspace default for new tasks. Existing tasks and runs keep their pinned environment."
            : "Changing this sets only this draft task. The workspace default is unchanged."
        let effect = selectedEnvironmentEffect(for: selectedEnvironment)
        return "\(scope) \(effect)"
    }

    var dockerIssueTitle: String? {
        imageInventoryIssue == nil ? nil : "Docker is not connected"
    }

    var dockerIssueSubtitle: String? {
        imageInventoryIssue == nil ? nil : "Start Docker Desktop, then refresh."
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
                return "GCP credentials required"
            case .pinnedTaskSnapshotMissingProjection:
                return "Task missing GCP credentials"
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
                return "BigQuery/dbt detected. Connect local ADC before running container tasks."
            case .pinnedTaskSnapshotMissingProjection:
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
        return hasGCPADCProjection ? "minus.circle.fill" : "link.circle.fill"
    }

    var credentialProjectionIsEnabled: Bool {
        canChangeActiveEnvironment && (hasGCPADCProjection || gcpADCCredentialFileExists)
    }

    var credentialProjectionHelp: String {
        if let report = credentialReadinessReport, report.shouldBlockLaunch {
            let remediation = report.remediation.map { " \($0)" } ?? ""
            return "\(report.detail)\(remediation)"
        }
        if !canChangeActiveEnvironment {
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
            errorMessage = "This task already has execution history, so its execution environment is pinned. Fork or start a new task to use another container."
            return
        }
        persist(option.environment)
    }

    func toggleGCPADCProjection() {
        guard selectedEnvironment.isContainerized else { return }
        guard canChangeActiveEnvironment else {
            errorMessage = "This task already has execution history, so its Docker credential projection is pinned. Fork or start a new task to change it."
            return
        }

        var environment = selectedEnvironment
        var projections = environment.effectiveCredentialProjections
        if hasGCPADCProjection {
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
        persist(environment)
        statusMessage = "GCP credentials connected"
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
                statusMessage = "Image built. Start a new task to use it."
            }
        case .failure(let error):
            let detail = error.localizedDescription
            errorMessage = detail
            statusMessage = nil
            if case .unavailable(let rawDetail) = error {
                imageInventoryIssue = rawDetail
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
        guard canChangeActiveEnvironment else {
            errorMessage = "This task already has execution history, so its execution environment is pinned. Fork or start a new task to use another container."
            AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
                "result": "blocked",
                "environment": environment.kind.rawValue,
                "scope": activeScopeLabel
            ], level: .warning)
            return
        }

        let json = ExecutionEnvironmentStore.encode(environment)
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
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", fields: [
            "result": "changed",
            "environment": environment.kind.rawValue,
            "environment_id": environment.id,
            "scope": activeScopeLabel
        ])
    }

    private func syncSelectedEnvironment() {
        if let selectedTask,
           let snapshot = selectedTask.executionEnvironmentSnapshotJSON,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedEnvironment = ExecutionEnvironmentStore.decode(snapshot)
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

    private static func deduplicated(_ candidates: [DockerWorkspaceCandidate]) -> [DockerWorkspaceCandidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            guard !seen.contains(candidate.id) else { return false }
            seen.insert(candidate.id)
            return true
        }
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
        let scope = selectedTask == nil
            ? "Select this to set the workspace default for new tasks."
            : "Select this to set the execution environment for this draft task."
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
