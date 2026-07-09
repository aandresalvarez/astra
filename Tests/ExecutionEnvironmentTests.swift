import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@Suite("Execution Environments")
struct ExecutionEnvironmentTests {
    @Test("Docker mount plan keeps input directories read-only")
    func dockerMountPlanKeepsInputDirectoriesReadOnly() throws {
        let root = try makeTempDir("docker-input-mount")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = (root as NSString).appendingPathComponent("workspace")
        let additional = (root as NSString).appendingPathComponent("additional")
        let input = (root as NSString).appendingPathComponent("input")
        for path in [workspace, additional, input] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let workspaceModel = Workspace(name: "Docker", primaryPath: workspace, additionalPaths: [additional])
        let task = AgentTask(title: "Review input", goal: "Read files", workspace: workspaceModel)
        task.inputs = [input]
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test",
            image: "astra/test:latest"
        ))

        let snapshot = DockerExecutionPlanner.snapshotForRun(task: task, currentDirectory: workspace)
        let additionalMount = try #require(snapshot.mounts.first { $0.hostPath == additional })
        let inputMount = try #require(snapshot.mounts.first { $0.hostPath == input })

        #expect(additionalMount.access == .readWrite)
        #expect(inputMount.access == .readOnly)
    }

    @Test("Docker discovery is inert for Dockerfile, compose, and devcontainer markers")
    func dockerDiscoveryClassifiesMarkers() throws {
        let root = try makeTempDir("docker-discovery")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "FROM scratch\n".write(
            toFile: (root as NSString).appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        try "services: {}\n".write(
            toFile: (root as NSString).appendingPathComponent("compose.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let devcontainerDir = (root as NSString).appendingPathComponent(".devcontainer")
        try FileManager.default.createDirectory(atPath: devcontainerDir, withIntermediateDirectories: true)
        try "{}".write(
            toFile: (devcontainerDir as NSString).appendingPathComponent("devcontainer.json"),
            atomically: true,
            encoding: .utf8
        )

        let candidates = DockerWorkspaceDiscoveryService.candidates(primaryPath: root, additionalPaths: [])

        let dockerfile = try #require(candidates.first { $0.environment.kind == .dockerfile })
        #expect(dockerfile.isRunnable == false)
        #expect(dockerfile.environment.image?.hasPrefix("astra-") == true)
        #expect(dockerfile.issue?.contains("inert") == true)

        let compose = try #require(candidates.first { $0.environment.kind == .dockerCompose })
        #expect(compose.isRunnable == false)
        #expect(compose.issue?.contains("inert") == true)

        let devcontainer = try #require(candidates.first { $0.environment.kind == .devcontainer })
        #expect(devcontainer.isRunnable == false)
        #expect(devcontainer.issue?.contains("inert") == true)
    }

    @Test("Docker image inventory parses loaded image references")
    func dockerImageInventoryParsesLoadedImages() {
        let images = DockerImageInventoryService.parseImageList("""
        astra-demo\tlatest\tsha256:111
        <none>\t<none>\tsha256:222
        astra-demo\tlatest\tsha256:111
        astra-api\tdev\tsha256:333
        """)

        #expect(images.map(\.name) == ["astra-api:dev", "astra-demo:latest"])
    }

    @Test("Docker image availability probes selected image directly")
    func dockerImageAvailabilityProbesSelectedImageDirectly() async throws {
        let runner = RecordingDockerRunner(results: [
            .exited(code: 0, stdout: "desktop-linux\n", stderr: ""),
            .exited(code: 0, stdout: "sha256:abc\n", stderr: "")
        ])
        let service = DockerImageInventoryService(runner: runner, environment: [:])

        let availability = try await service.checkImageAvailability("astra/test:latest").get()

        #expect(availability.image == "astra/test:latest")
        #expect(availability.imageID == "sha256:abc")
        let calls = await runner.recordedCalls()
        #expect(calls.map(\.args) == [
            ["docker", "context", "show"],
            ["docker", "image", "inspect", "--format", "{{.Id}}", "astra/test:latest"]
        ])
    }

    @Test("Docker image availability reports missing image")
    func dockerImageAvailabilityReportsMissingImage() async throws {
        let runner = RecordingDockerRunner(results: [
            .exited(code: 0, stdout: "desktop-linux\n", stderr: ""),
            .exited(code: 1, stdout: "", stderr: "Error response from daemon: No such image: astra/missing:latest\n")
        ])
        let service = DockerImageInventoryService(runner: runner, environment: [:])

        let availability = await service.checkImageAvailability("astra/missing:latest")

        #expect(availability.failure == .missingImage("astra/missing:latest"))
        let calls = await runner.recordedCalls()
        #expect(calls.map(\.args) == [
            ["docker", "context", "show"],
            ["docker", "image", "inspect", "--format", "{{.Id}}", "astra/missing:latest"]
        ])
    }

    @Test("Docker launch planning keeps provider on host by default and routes workspace commands through Docker")
    func dockerPlannerKeepsProviderOnHostByDefault() throws {
        let root = try makeTempDir("docker-plan-host-provider")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Run", goal: "Run in container", workspace: workspace)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest"
        )
        let base = makeBasePlan(currentDirectory: root)

        let plan = try DockerExecutionPlanner.plan(
            base: base,
            environment: environment,
            task: task,
            runID: UUID()
        ).get()

        #expect(plan.executablePath == "/host/claude")
        #expect(plan.arguments == ["--print"])
        #expect(plan.executionEnvironment.workspaceCommandsRunInsideContainer)
        #expect(plan.commandPlannedFields["workspace_executor_mode"] == "host_provider_container_workspace")
        #expect(plan.commandPlannedFields["workspace_command_placement"] == "docker")
        #expect(plan.commandPlannedFields["shell_route"] == "astra_workspace_mcp")
        #expect(plan.commandPlannedFields["os_sandbox_claim"] == "true")
        #expect(plan.commandPlannedFields["container_image"] == "astra/test:latest")
        #expect(plan.pathMapper?.containerPath(forHostPath: root) == "/workspace")
    }

    @MainActor
    @Test("Docker prompt section tells the provider to use the ASTRA workspace shell MCP tool")
    func dockerPromptSectionUsesWorkspaceShellToolForHostProviderMode() throws {
        let root = try makeTempDir("docker-prompt")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Run", goal: "Run in container", workspace: workspace)
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(
                    hostPath: (root as NSString).appendingPathComponent(".config/gcloud")
                )
            ]
        ))

        let section = try #require(AgentPromptExecutionEnvironmentSection.section(for: task, codeDir: root))

        #expect(section.text.contains("Provider placement: host macOS"))
        #expect(section.text.contains("Workspace command executor: Docker image astra/test:latest"))
        #expect(section.text.contains("mcp__astra_workspace__workspace_shell"))
        #expect(section.text.contains("astra_workspace-workspace_shell"))
        #expect(section.text.contains("Claude-style and Codex runtimes"))
        #expect(section.text.contains("synchronous shell calls are intentionally bounded"))
        #expect(section.text.contains("short `workspace_job_wait` polling windows"))
        #expect(section.text.contains("Do not use native host Bash"))
        #expect(section.text.contains("Routing contract: provider reasoning runs on host macOS"))
        #expect(section.text.contains("host control-plane actions such as GitHub PR metadata, Jira, read-only Google Cloud checks, SSH, browser, and Keychain access"))
        #expect(section.text.contains("`mcp__astra_host__gcloud`"))
        #expect(section.text.contains("Use `mcp__astra_host__bq` only for bq help/version metadata"))
        #expect(section.text.contains("BigQuery data access is not available through host-control"))
        #expect(!section.text.contains("`mcp__astra_host__gcloud`, `mcp__astra_host__bq`"))
        #expect(!section.text.contains("astra_host-gcloud`, `astra_host-bq`"))
        #expect(section.text.contains("Do not ask a subagent to \"run locally\""))
        #expect(section.text.contains("Path mapping: inside workspace MCP tools"))
        #expect(section.text.contains("Do not run `cd /Users/...`"))
        #expect(section.text.contains("Prefer tools installed in the image environment"))
        #expect(section.text.contains("command -v dbt && dbt --version"))
        #expect(section.text.contains("verify credential readiness from inside the container"))
        #expect(section.text.contains("GOOGLE_APPLICATION_CREDENTIALS"))
        #expect(section.text.contains("gcloud auth application-default print-access-token --quiet >/dev/null"))
        #expect(section.text.contains("Never print access tokens into tool output or logs."))
        #expect(section.text.contains("Do not use host-created virtual environments"))
        #expect(section.text.contains("/workspace/.venv"))
        #expect(section.text.contains("Credential projections: GCP Application Default Credentials mounted read-only at /root/.config/gcloud."))
    }

    @Test("Docker launch planning builds a typed docker run command with minimal environment")
    func dockerPlannerBuildsRunCommand() throws {
        let root = try makeTempDir("docker-plan")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Run", goal: "Run in container", workspace: workspace)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest",
            runtimeExecutablePath: "/usr/local/bin/claude",
            providerPlacement: .container,
            environmentKeyAllowlist: ["FOO"]
        )
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(environment)
        let base = makeBasePlan(currentDirectory: root, environment: [
            "FOO": "bar",
            "SECRET": "nope"
        ])

        let result = DockerExecutionPlanner.plan(
            base: base,
            environment: DockerExecutionPlanner.snapshotForRun(task: task, currentDirectory: root),
            task: task,
            runID: UUID()
        )
        let plan = try result.get()

        #expect(plan.executablePath == "/usr/bin/env")
        #expect(plan.arguments.prefix(3) == ["docker", "run", "--rm"])
        #expect(plan.arguments.contains("astra/test:latest"))
        let imageIndex = try #require(plan.arguments.firstIndex(of: "astra/test:latest"))
        #expect(imageIndex > 0)
        #expect(plan.arguments[imageIndex - 1] == "--")
        #expect(plan.arguments.contains("/usr/local/bin/claude"))
        #expect(plan.arguments.contains("--workdir"))
        #expect(plan.arguments.contains("/workspace"))
        #expect(plan.environment["FOO"] == "bar")
        #expect(plan.environment["SECRET"] == nil)
        #expect(plan.pathMapper?.hostPath(forContainerPath: "/workspace/file.txt") == (root as NSString).appendingPathComponent("file.txt"))
        #expect(plan.commandPlannedFields["os_sandbox_claim"] == "false")
        #expect(plan.commandPlannedFields["workspace_executor_mode"] == "provider_inside_container")
        #expect(plan.commandPlannedFields["workspace_command_placement"] == "docker")
        #expect(plan.commandPlannedFields["shell_route"] == "provider_inside_container")
        #expect(plan.commandPlannedFields["container_executable_source"] == "environment")
        #expect(plan.commandPlannedFields["container_image"] == "astra/test:latest")
        #expect(plan.commandPlannedFields["container_workdir"] == "/workspace")
        #expect(plan.commandPlannedFields["container_executable"] == "/usr/local/bin/claude")
        #expect(plan.commandPlannedFields["container_mount_summary"]?.contains("\(root)=/workspace") == true)
    }

    @Test("Docker credential projections mount ADC read-only and forward path environment")
    func dockerCredentialProjectionsFlowIntoContainerPlans() throws {
        let root = try makeTempDir("docker-credential-plan")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let gcloudPath = (root as NSString).appendingPathComponent(".config/gcloud")
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Run", goal: "Run in container", workspace: workspace)
        let projection = ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcloudPath)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest",
            runtimeExecutablePath: "/usr/local/bin/claude",
            providerPlacement: .container,
            credentialProjections: [projection]
        )
        let base = makeBasePlan(currentDirectory: root)

        let plan = try DockerExecutionPlanner.plan(
            base: base,
            environment: environment,
            task: task,
            runID: UUID()
        ).get()

        #expect(plan.arguments.contains("--volume"))
        #expect(plan.arguments.contains("\(gcloudPath):/root/.config/gcloud:ro"))
        #expect(plan.arguments.contains("--env"))
        #expect(plan.arguments.contains("CLOUDSDK_CONFIG"))
        #expect(plan.arguments.contains("GOOGLE_APPLICATION_CREDENTIALS"))
        #expect(!plan.arguments.contains { $0.hasPrefix("GOOGLE_APPLICATION_CREDENTIALS=") })
        #expect(plan.environment["CLOUDSDK_CONFIG"] == "/root/.config/gcloud")
        #expect(plan.environment["GOOGLE_APPLICATION_CREDENTIALS"] == "/root/.config/gcloud/application_default_credentials.json")
        #expect(plan.commandPlannedFields["container_credential_projection_count"] == "1")
        #expect(plan.commandPlannedFields["container_credential_projection_summary"]?.contains("/root/.config/gcloud") == true)

        let mcpVariables = DockerWorkspaceMCPProjection.environmentVariables(
            task: task,
            environment: WorkspaceExecutionEnvironment(
                id: "image:test",
                kind: .dockerImage,
                displayName: "Test Image",
                image: "astra/test:latest",
                credentialProjections: [projection]
            ),
            currentDirectory: root,
            runID: UUID(uuidString: "5EB2B3FA-CB19-4B0D-8BB2-D0673C49B113")
        )
        let mounts = try jsonArray(mcpVariables["ASTRA_WORKSPACE_DOCKER_MOUNTS"])
        let credentialMount = try #require(mounts.first { $0["role"] as? String == "credential" })
        #expect(credentialMount["hostPath"] as? String == gcloudPath)
        #expect(credentialMount["containerPath"] as? String == "/root/.config/gcloud")
        #expect(credentialMount["access"] as? String == "ro")
        let containerEnvironment = try #require(jsonDictionary(mcpVariables["ASTRA_WORKSPACE_DOCKER_ENV"]) as? [String: String])
        #expect(containerEnvironment["CLOUDSDK_CONFIG"] == "/root/.config/gcloud")
        #expect(containerEnvironment["GOOGLE_APPLICATION_CREDENTIALS"] == "/root/.config/gcloud/application_default_credentials.json")
    }

    @Test("Docker credential readiness blocks BigQuery workspaces when host ADC is not projected")
    func dockerCredentialReadinessBlocksBigQueryWorkspaceWithoutProjection() throws {
        let root = try makeTempDir("docker-credential-readiness-missing")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-credential-readiness-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeADCFile(inHome: home)
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        ))
        let task = AgentTask(title: "Run dbt", goal: "Check BigQuery", workspace: workspace)

        let report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: root,
            homeDirectoryPath: home
        )

        #expect(report.state == .hostCredentialAvailableButNotProjected)
        #expect(report.shouldBlockLaunch)
        #expect(report.requiredProjectionIDs == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(report.evidence.contains("dbt/profiles.yml"))
        #expect(report.userMessage.contains("Container credential preflight stopped this task"))
    }

    @Test("Docker credential readiness passes BigQuery workspaces when ADC is projected")
    func dockerCredentialReadinessPassesBigQueryWorkspaceWithProjection() throws {
        let root = try makeTempDir("docker-credential-readiness-ready")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-credential-readiness-ready-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gcloudDirectory = try writeADCFile(inHome: home)
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcloudDirectory)
            ]
        ))
        let task = AgentTask(title: "Run dbt", goal: "Check BigQuery", workspace: workspace)

        let report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: root,
            homeDirectoryPath: home
        )

        #expect(report.state == .ready)
        #expect(!report.shouldBlockLaunch)
        #expect(report.projectedContainerPath == ExecutionEnvironmentCredentialProjection.gcpADCContainerPath)
        #expect(report.projectedEnvironmentKeys == ["CLOUDSDK_CONFIG", "GOOGLE_APPLICATION_CREDENTIALS"])
    }

    @Test("Docker credential readiness detects pinned task snapshots missing workspace credentials")
    func dockerCredentialReadinessDetectsPinnedSnapshotMissingProjection() throws {
        let root = try makeTempDir("docker-credential-readiness-stale")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-credential-readiness-stale-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gcloudDirectory = try writeADCFile(inHome: home)
        let staleEnvironment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        )
        let connectedEnvironment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcloudDirectory)
            ]
        )
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(connectedEnvironment)
        let task = AgentTask(title: "Run dbt", goal: "Check BigQuery", workspace: workspace)
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(staleEnvironment)

        let report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: root,
            homeDirectoryPath: home
        )

        #expect(report.state == .pinnedTaskSnapshotMissingProjection)
        #expect(report.shouldBlockLaunch)
        #expect(report.isTaskSnapshotStale)
        #expect(report.remediation?.contains("Update task credentials") == true)
    }

    @MainActor
    @Test("Credential projection preflight stops provider launch when local ADC is missing")
    func credentialProjectionPreflightStopsProviderLaunchWhenLocalADCIsMissing() throws {
        let root = try makeTempDir("docker-credential-preflight")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-credential-preflight-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        ))
        let task = AgentTask(title: "Run dbt", goal: "Check BigQuery", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let result = AgentRuntimeLaunchPreflight.preflightCredentialProjectionBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "test",
            codeDirectory: root,
            homeDirectoryPath: home
        )

        #expect(!result.didPass)
        #expect(result.status == .credentialProjectionFailed)
        #expect(result.reason == TaskRunStopReason.credentialProjectionRequired.rawValue)
        #expect(run.status == .failed)
        #expect(run.typedStopReason == .credentialProjectionRequired)
        #expect(task.status == .failed)
    }

    @MainActor
    @Test("Credential projection preflight auto-projects local ADC for Docker retries")
    func credentialProjectionPreflightAutoProjectsLocalADCForDockerRetries() throws {
        let root = try makeTempDir("docker-credential-auto-project")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-credential-auto-project-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gcloudDirectory = try writeADCFile(inHome: home)
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        )
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(.host)
        let task = AgentTask(title: "Run dbt", goal: "Check BigQuery", workspace: workspace)
        task.status = .failed
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        let previousRun = TaskRun(task: task)
        previousRun.status = .failed
        previousRun.output = "provider already changed files"
        previousRun.outputTokens = 5
        previousRun.executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        let retryRun = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(previousRun)
        context.insert(retryRun)

        let result = AgentRuntimeLaunchPreflight.preflightCredentialProjectionBeforeLaunchResult(
            task: task,
            run: retryRun,
            modelContext: context,
            phase: "retry",
            codeDirectory: root,
            homeDirectoryPath: home
        )

        #expect(result.didPass)
        #expect(result.status == .credentialProjectionPassed)
        #expect(result.auditFields["auto_projected_credentials"] == "true")
        let taskEnvironment = ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON)
        let retryEnvironment = ExecutionEnvironmentStore.decode(retryRun.executionEnvironmentSnapshotJSON)
        let previousRunEnvironment = ExecutionEnvironmentStore.decode(previousRun.executionEnvironmentSnapshotJSON)
        let workspaceEnvironment = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(taskEnvironment.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(taskEnvironment.effectiveCredentialProjections.first?.hostPath == gcloudDirectory)
        #expect(retryEnvironment.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(previousRunEnvironment.effectiveCredentialProjections.isEmpty)
        #expect(workspaceEnvironment.isHost)
    }

    @Test("Docker launch planning falls back to provider binary name inside the image")
    func dockerPlannerUsesProviderBinaryNameWhenContainerExecutableIsNotConfigured() throws {
        let root = try makeTempDir("docker-plan-provider")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Run", goal: "Run in container", workspace: workspace)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest",
            providerPlacement: .container
        )
        let base = makeBasePlan(currentDirectory: root)

        let plan = try DockerExecutionPlanner.plan(
            base: base,
            environment: DockerExecutionPlanner.snapshotForRun(task: task, currentDirectory: root).isHost
                ? environment
                : DockerExecutionPlanner.snapshotForRun(task: task, currentDirectory: root),
            task: task,
            runID: UUID()
        ).get()

        #expect(plan.arguments.contains("claude"))
        #expect(plan.commandPlannedFields["container_executable_source"] == "provider_basename")
    }

    @Test("Docker launch failures identify missing provider executables inside the image")
    func dockerLaunchFailuresIdentifyMissingProviderExecutable() throws {
        let root = try makeTempDir("docker-failure-diagnostic")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let task = AgentTask(title: "Run", goal: "Run", workspace: Workspace(name: "Docker", primaryPath: root))
        let environment = WorkspaceExecutionEnvironment(
            id: "image:astra-starr-data-lake:latest",
            kind: .dockerImage,
            displayName: "starr-data-lake Image",
            image: "astra-starr-data-lake:latest",
            providerPlacement: .container
        )
        let plan = try DockerExecutionPlanner.plan(
            base: makeBasePlan(currentDirectory: root),
            environment: environment,
            task: task,
            runID: UUID(uuidString: "67A17493-5FFA-47AB-9CB0-F304DE933B89")
        ).get()
        let error = """
        docker: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: exec: "claude": executable file not found in $PATH
        Run 'docker run --help' for more information
        """

        let diagnostic = try #require(DockerRuntimeFailureDiagnostics.diagnose(
            exitCode: 127,
            error: error,
            plan: plan
        ))

        #expect(diagnostic.stopReason == TaskRunStopReason.dockerProviderExecutableMissing.rawValue)
        #expect(diagnostic.message.contains("Missing provider executable \"claude\""))
        #expect(diagnostic.message.contains("astra-starr-data-lake:latest"))
        #expect(diagnostic.auditFields["docker_failure_kind"] == "provider_executable_missing")
        #expect(diagnostic.auditFields["missing_executable"] == "claude")
        #expect(diagnostic.auditFields["container_image"] == "astra-starr-data-lake:latest")
        #expect(diagnostic.auditFields["docker_exit_code"] == "127")
    }

    @Test("Docker launch planning fails closed for unsafe container policy")
    func dockerPlannerDeniesUnsafeOptions() throws {
        let root = try makeTempDir("docker-deny")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let task = AgentTask(title: "Run", goal: "Run", workspace: Workspace(name: "Docker", primaryPath: root))
        let base = makeBasePlan(currentDirectory: root)

        let privileged = WorkspaceExecutionEnvironment(
            id: "bad",
            kind: .dockerImage,
            displayName: "Bad",
            image: "x",
            runtimeExecutablePath: "/bin/tool",
            privileged: true
        )
        #expect(DockerExecutionPlanner.plan(base: base, environment: privileged, task: task, runID: nil).failure == .privilegedDenied)

        let hostNetwork = WorkspaceExecutionEnvironment(
            id: "bad-network",
            kind: .dockerImage,
            displayName: "Bad Network",
            image: "x",
            runtimeExecutablePath: "/bin/tool",
            networkMode: "host"
        )
        #expect(DockerExecutionPlanner.plan(base: base, environment: hostNetwork, task: task, runID: nil).failure == .hostNetworkDenied)

        let socket = WorkspaceExecutionEnvironment(
            id: "socket",
            kind: .dockerImage,
            displayName: "Socket",
            image: "x",
            runtimeExecutablePath: "/bin/tool",
            mounts: [
                ExecutionEnvironmentMount(
                    hostPath: "/var/run/docker.sock",
                    containerPath: "/var/run/docker.sock",
                    access: .readWrite,
                    role: .additionalPath
                )
            ]
        )
        #expect(DockerExecutionPlanner.plan(base: base, environment: socket, task: task, runID: nil).failure == .dockerSocketDenied)

        let dockerDesktopSocket = WorkspaceExecutionEnvironment(
            id: "desktop-socket",
            kind: .dockerImage,
            displayName: "Desktop Socket",
            image: "x",
            runtimeExecutablePath: "/bin/tool",
            mounts: [
                ExecutionEnvironmentMount(
                    hostPath: "\(NSHomeDirectory())/.docker/run/docker.sock",
                    containerPath: "/var/run/docker.sock",
                    access: .readWrite,
                    role: .additionalPath
                )
            ]
        )
        #expect(DockerExecutionPlanner.plan(
            base: base,
            environment: dockerDesktopSocket,
            task: task,
            runID: nil
        ).failure == .dockerSocketDenied)

        let optionImage = WorkspaceExecutionEnvironment(
            id: "option-image",
            kind: .dockerImage,
            displayName: "Option Image",
            image: "--privileged",
            runtimeExecutablePath: "/bin/tool"
        )
        #expect(DockerExecutionPlanner.plan(
            base: base,
            environment: optionImage,
            task: task,
            runID: nil
        ).failure == .invalidImageReference("--privileged"))

        let spacedImage = WorkspaceExecutionEnvironment(
            id: "spaced-image",
            kind: .dockerImage,
            displayName: "Spaced Image",
            image: "alpine --privileged",
            runtimeExecutablePath: "/bin/tool"
        )
        #expect(DockerExecutionPlanner.plan(
            base: base,
            environment: spacedImage,
            task: task,
            runID: nil
        ).failure == .invalidImageReference("alpine --privileged"))
    }

    @Test("Imported credential projections are closed to ASTRA-owned GCP ADC")
    func importedCredentialProjectionsAreSanitized() throws {
        let root = try makeTempDir("docker-credential-sanitize")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let gcloudPath = (root as NSString).appendingPathComponent(".config/gcloud")
        let imported = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection(
                    id: ExecutionEnvironmentCredentialProjection.gcpADCID,
                    kind: .gcpADC,
                    displayName: "Tampered ADC",
                    hostPath: gcloudPath,
                    containerPath: "/tmp/not-gcloud",
                    access: .readWrite,
                    environment: ["LD_PRELOAD": "/evil.dylib"]
                ),
                ExecutionEnvironmentCredentialProjection(
                    id: "host-root",
                    kind: .genericDirectory,
                    displayName: "Host Root",
                    hostPath: "/",
                    containerPath: "/host",
                    access: .readWrite,
                    environment: ["PATH": "/tmp/bin"]
                )
            ]
        )

        let projections = imported.effectiveCredentialProjections

        #expect(projections.count == 1)
        let projection = try #require(projections.first)
        #expect(projection.id == ExecutionEnvironmentCredentialProjection.gcpADCID)
        #expect(projection.hostPath == gcloudPath)
        #expect(projection.containerPath == ExecutionEnvironmentCredentialProjection.gcpADCContainerPath)
        #expect(projection.access == .readOnly)
        #expect(projection.environment == [
            "CLOUDSDK_CONFIG": ExecutionEnvironmentCredentialProjection.gcpADCContainerPath,
            "GOOGLE_APPLICATION_CREDENTIALS": "\(ExecutionEnvironmentCredentialProjection.gcpADCContainerPath)/\(ExecutionEnvironmentCredentialProjection.gcpADCFileName)"
        ])
    }

    @Test("Credential projection sanitization fails closed when the host path cannot be canonicalized")
    func credentialProjectionSanitizationFailsClosedForUncanonicalizablePath() throws {
        let root = try makeTempDir("docker-credential-sanitize-uncanonicalizable")
        defer { try? FileManager.default.removeItem(atPath: root) }
        // An interior newline still ends in "/.config/gcloud" (so it clears the
        // filename shape check) but ExecutionSandbox.canonicalize refuses to
        // resolve it, returning nil. The sanitizer must reject this rather than
        // skip the root-safety checks and approve it.
        let poisonedPath = "\(root)/evil\npath/.config/gcloud"
        let imported = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: poisonedPath)
            ]
        )

        #expect(imported.effectiveCredentialProjections.isEmpty)
    }

    @Test("Run file changes translate container paths into host paths")
    func runFileChangesTranslateContainerPaths() throws {
        let root = try makeTempDir("docker-file-change")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let task = AgentTask(title: "Run", goal: "Run", workspace: Workspace(name: "Docker", primaryPath: root))
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test",
            runtimeExecutablePath: "/bin/tool",
            mounts: [
                ExecutionEnvironmentMount(
                    hostPath: root,
                    containerPath: "/workspace",
                    access: .readWrite,
                    role: .workspace
                )
            ]
        )
        let run = TaskRun(task: task)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(environment)

        run.appendFileChange(StoredFileChange(
            path: "/workspace/output.txt",
            changeType: StoredFileChangeKind.write.rawValue,
            content: "ok",
            oldString: nil,
            newString: nil
        ))

        #expect(run.fileChanges.map(\.path) == [(root as NSString).appendingPathComponent("output.txt")])
    }

    @Test("Docker readiness rejects remote contexts by default")
    func dockerReadinessRejectsRemoteContext() {
        let status = DockerReadinessService.evaluate(
            dockerStatus: .healthy(path: "/usr/local/bin/docker", version: "25.0"),
            dockerContext: "prod-remote",
            dockerHost: nil
        )
        #expect(status.state == .unsafeRemoteContext)

        let local = DockerReadinessService.evaluate(
            dockerStatus: .healthy(path: "/usr/local/bin/docker", version: "25.0"),
            dockerContext: "desktop-linux",
            dockerHost: "unix:///var/run/docker.sock"
        )
        #expect(local.state == .ready)
    }

    @Test("Docker image build service runs docker build with the discovered Dockerfile")
    func dockerImageBuildServiceRunsDockerBuild() async throws {
        let runner = RecordingDockerRunner(results: [
            .exited(code: 0, stdout: "desktop-linux\n", stderr: ""),
            .exited(code: 0, stdout: "built\n", stderr: "")
        ])
        let service = DockerImageBuildService(runner: runner, environment: [:], timeout: 42)
        let request = DockerImageBuildRequest(
            image: "astra-demo:latest",
            dockerfilePath: "/tmp/demo/Dockerfile",
            sourcePath: "/tmp/demo"
        )

        let result = await service.buildImage(request)

        let summary = try result.get()
        #expect(summary.image == "astra-demo:latest")
        let calls = await runner.recordedCalls()
        #expect(calls.map(\.args) == [
            ["docker", "context", "show"],
            ["docker", "build", "-t", "astra-demo:latest", "-f", "/tmp/demo/Dockerfile", "/tmp/demo"]
        ])
        #expect(calls.map(\.timeout) == [3, 42])
    }

    @Test("Workspace export and import preserve execution environment snapshots")
    @MainActor
    func workspaceConfigRoundTripsExecutionEnvironment() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = try makeTempDir("docker-roundtrip")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test",
            runtimeExecutablePath: "/bin/tool",
            environmentKeyAllowlist: ["TOKEN_NAME"],
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(
                    hostPath: (root as NSString).appendingPathComponent(".config/gcloud")
                )
            ]
        )
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(environment)
        let task = AgentTask(title: "Task", goal: "Run", workspace: workspace)
        task.executionEnvironmentSnapshotJSON = workspace.activeExecutionEnvironmentJSON
        let run = TaskRun(task: task)
        run.executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let importedContainer = try makeContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)

        let importedEnvironment = ExecutionEnvironmentStore.decode(imported.activeExecutionEnvironmentJSON)
        #expect(importedEnvironment.kind == .dockerImage)
        #expect(importedEnvironment.environmentKeyAllowlist == ["TOKEN_NAME"])
        #expect(importedEnvironment.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        let importedTask = try #require(imported.tasks.first)
        #expect(ExecutionEnvironmentStore.decode(importedTask.executionEnvironmentSnapshotJSON).id == "image:test")
        let importedRun = try #require(importedTask.runs.first)
        #expect(ExecutionEnvironmentStore.decode(importedRun.executionEnvironmentSnapshotJSON).id == "image:test")
    }

    @MainActor
    @Test("Docker view model promotes loaded workspace images into selectable environments")
    func dockerViewModelPromotesLoadedWorkspaceImages() async throws {
        let root = try makeTempDir("docker-viewmodel")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "FROM scratch\n".write(
            toFile: (root as NSString).appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([
            DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:abc")
        ])))
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()
        let imageCandidate = try #require(viewModel.candidates.first { $0.environment.kind == .dockerImage })
        #expect(viewModel.runnableCandidates == [imageCandidate])
        #expect(viewModel.environmentPickerTitle == "Run new tasks in")
        #expect(viewModel.environmentPickerSubtitle == "Host - providers run directly on macOS")
        #expect(viewModel.environmentPickerHelp.contains("workspace default for new tasks"))
        #expect(viewModel.environmentOptions.map(\.title) == [
            "Host",
            "\(URL(fileURLWithPath: root).lastPathComponent) Image"
        ])
        #expect(viewModel.environmentOptions.map(\.isSelected) == [true, false])
        viewModel.selectCandidate(imageCandidate)

        let selected = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(selected.kind == .dockerImage)
        #expect(selected.image == "\(repository):latest")
        #expect(viewModel.environmentPickerSubtitle == "\(URL(fileURLWithPath: root).lastPathComponent) Image - commands in \(repository):latest")
        #expect(viewModel.environmentPickerHelp.contains("route project shell commands through Docker image \(repository):latest"))
        #expect(viewModel.environmentOptions.map(\.isSelected) == [false, true])
        #expect(AgentTask(title: "Task", goal: "Run", workspace: workspace).executionEnvironmentSnapshotJSON == workspace.activeExecutionEnvironmentJSON)
    }

    @MainActor
    @Test("Docker view model exposes explicit runtime routing contract")
    func dockerViewModelExposesRuntimeRoutingContract() async throws {
        let root = try makeTempDir("docker-contract")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([
            DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:abc")
        ])))
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()
        #expect(viewModel.runtimeContractRows.map(\.title) == [
            "Provider: Host",
            "Workspace commands: Host"
        ])

        viewModel.selectEnvironmentOption("image:\(repository):latest")

        #expect(viewModel.runtimeContractRows.map(\.title).contains("Provider: Host"))
        #expect(viewModel.runtimeContractRows.map(\.title).contains("Workspace commands: Docker image"))
        #expect(viewModel.runtimeContractRows.map(\.title).contains("Host capabilities: ASTRA managed"))
        #expect(viewModel.runtimeContractRows.contains {
            $0.subtitle.contains("Project shell runs in \(repository):latest")
        })
        #expect(viewModel.runtimeContractRows.contains {
            $0.subtitle.contains("GitHub, Jira, GCloud, SSH, browser, and Keychain")
        })
    }

    @MainActor
    @Test("Docker view model offers explicit retry in Docker for legacy Host-pinned tasks")
    func dockerViewModelSwitchesLegacyHostPinnedTaskToWorkspaceImageForNextRetry() async throws {
        let root = try makeTempDir("docker-pinned-switch")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        )
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(environment)

        let task = AgentTask(title: "Historical Host", goal: "Run dbt", workspace: workspace)
        task.status = .completed
        // Simulate tasks created before Host was stored as an explicit snapshot.
        task.executionEnvironmentSnapshotJSON = nil
        #expect(DockerExecutionPlanner.resolveEnvironment(for: task).isHost)

        let viewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([])))
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        #expect(viewModel.selectedEnvironment.isHost)
        #expect(viewModel.canSwitchPinnedTaskToWorkspaceEnvironment)
        #expect(viewModel.pinnedTaskEnvironmentActionTitle == "Retry in Test Image")
        #expect(viewModel.pinnedTaskEnvironmentActionSubtitle.contains("astra/test:latest"))

        viewModel.switchPinnedTaskToWorkspaceEnvironment()

        let taskEnvironment = ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON)
        #expect(taskEnvironment.id == "image:test")
        #expect(taskEnvironment.workspaceCommandsRunInsideContainer)
        #expect(DockerExecutionPlanner.resolveEnvironment(for: task).id == "image:test")
        #expect(viewModel.selectedEnvironment.id == "image:test")
        #expect(viewModel.statusMessage == "Next retry will use Test Image")
        #expect(!viewModel.canSwitchPinnedTaskToWorkspaceEnvironment)
    }

    @MainActor
    @Test("Docker view model connects and disconnects GCP ADC projections")
    func dockerViewModelTogglesGCPADCProjection() async throws {
        let root = try makeTempDir("docker-viewmodel-gcp")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = try makeTempDir("docker-viewmodel-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gcloudDirectory = (home as NSString).appendingPathComponent(".config/gcloud")
        try FileManager.default.createDirectory(atPath: gcloudDirectory, withIntermediateDirectories: true)
        try "{}".write(
            toFile: (gcloudDirectory as NSString)
                .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName),
            atomically: true,
            encoding: .utf8
        )
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest"
        ))
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: FakeDockerImageInventory(result: .success([])),
            homeDirectoryPath: home
        )
        viewModel.setWorkspaceForTesting(workspace)

        #expect(viewModel.shouldShowCredentialProjectionRow)
        #expect(viewModel.credentialProjectionTitle == "Connect GCP credentials")
        #expect(viewModel.credentialProjectionIsEnabled)

        viewModel.toggleGCPADCProjection()

        let connected = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(connected.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(connected.effectiveCredentialProjections.first?.hostPath == gcloudDirectory)
        #expect(viewModel.credentialProjectionTitle == "GCP credentials connected")
        #expect(viewModel.statusMessage == "GCP credentials connected")

        viewModel.toggleGCPADCProjection()

        let disconnected = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(disconnected.effectiveCredentialProjections.isEmpty)
        #expect(viewModel.credentialProjectionTitle == "Connect GCP credentials")
        #expect(viewModel.statusMessage == "GCP credentials disconnected")
    }

    @MainActor
    @Test("Docker view model repairs setup-only credential projection failures")
    func dockerViewModelRepairsSetupOnlyCredentialProjectionFailures() async throws {
        let root = try makeTempDir("docker-viewmodel-gcp-repair")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-viewmodel-gcp-repair-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gcloudDirectory = try writeADCFile(inHome: home)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        )
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(environment)
        let task = AgentTask(title: "Task", goal: "Run dbt", workspace: workspace)
        task.status = .failed
        task.executionEnvironmentSnapshotJSON = workspace.activeExecutionEnvironmentJSON
        let run = TaskRun(task: task)
        run.status = .failed
        run.typedStopReason = .credentialProjectionRequired
        run.completedAt = Date()
        task.runs = [run]

        let viewModel = WorkspaceDockerViewModel(
            imageInventory: FakeDockerImageInventory(result: .success([])),
            homeDirectoryPath: home
        )
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        #expect(viewModel.canChangeActiveEnvironment == false)
        #expect(viewModel.canRepairCredentialProjection)
        #expect(viewModel.credentialProjectionTitle == "Connect task GCP credentials")
        #expect(viewModel.credentialProjectionSubtitle.contains("then retry"))
        #expect(viewModel.credentialProjectionIsEnabled)
        #expect(viewModel.credentialProjectionHelp.contains("setup-only failed task"))

        viewModel.toggleGCPADCProjection()

        let taskEnvironment = ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON)
        let workspaceEnvironment = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(taskEnvironment.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(taskEnvironment.effectiveCredentialProjections.first?.hostPath == gcloudDirectory)
        #expect(workspaceEnvironment.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(viewModel.statusMessage == "GCP credentials connected. Retry this task.")
        #expect(viewModel.errorMessage == nil)
        #expect(task.status == .failed)
        #expect(viewModel.credentialProjectionTitle == "GCP credentials ready")
        #expect(viewModel.credentialProjectionIsEnabled == false)
        #expect(viewModel.credentialProjectionActionSystemName == "checkmark.circle.fill")

        let report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: root,
            homeDirectoryPath: home
        )
        #expect(report.state == .ready)
        #expect(!report.shouldBlockLaunch)

        viewModel.toggleGCPADCProjection()

        let repairedEnvironmentAfterExtraClick = ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON)
        #expect(repairedEnvironmentAfterExtraClick.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.statusMessage == "GCP credentials are connected. Retry this task.")

        let container = try makeContainer()
        let context = container.mainContext
        context.insert(workspace)
        context.insert(task)
        let retryRun = TaskRun(task: task)
        context.insert(retryRun)
        let preflight = AgentRuntimeLaunchPreflight.preflightCredentialProjectionBeforeLaunchResult(
            task: task,
            run: retryRun,
            modelContext: context,
            phase: "test",
            codeDirectory: root,
            homeDirectoryPath: home
        )
        #expect(preflight.status == .credentialProjectionPassed)
        #expect(preflight.reason == nil)
    }

    @MainActor
    @Test("Docker view model connects credentials for substantive pinned task next retry")
    func dockerViewModelConnectsCredentialProjectionForSubstantivePinnedTaskNextRetry() async throws {
        let root = try makeTempDir("docker-viewmodel-gcp-no-repair")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigQueryDBTProfile(in: root)
        let home = try makeTempDir("docker-viewmodel-gcp-no-repair-home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gcloudDirectory = try writeADCFile(inHome: home)
        let workspace = Workspace(name: "Docker", primaryPath: root)
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            sourcePath: root,
            image: "astra/test:latest"
        ))
        let task = AgentTask(title: "Task", goal: "Run dbt", workspace: workspace)
        task.status = .failed
        task.executionEnvironmentSnapshotJSON = workspace.activeExecutionEnvironmentJSON
        let run = TaskRun(task: task)
        run.status = .failed
        run.typedStopReason = .failed
        run.output = "provider started"
        run.outputTokens = 5
        run.executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        task.runs = [run]

        let viewModel = WorkspaceDockerViewModel(
            imageInventory: FakeDockerImageInventory(result: .success([])),
            homeDirectoryPath: home
        )
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        #expect(viewModel.canRepairCredentialProjection == false)
        #expect(viewModel.canUpdatePinnedTaskCredentialProjection)
        #expect(viewModel.credentialProjectionTitle == "Connect task GCP credentials")
        #expect(viewModel.credentialProjectionSubtitle.contains("next retry"))
        #expect(viewModel.credentialProjectionIsEnabled)
        #expect(viewModel.credentialProjectionHelp.contains("Earlier run manifests stay unchanged"))

        viewModel.toggleGCPADCProjection()

        let taskEnvironment = ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON)
        let runEnvironment = ExecutionEnvironmentStore.decode(run.executionEnvironmentSnapshotJSON)
        let workspaceEnvironment = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(taskEnvironment.effectiveCredentialProjections.map(\.id) == [ExecutionEnvironmentCredentialProjection.gcpADCID])
        #expect(taskEnvironment.effectiveCredentialProjections.first?.hostPath == gcloudDirectory)
        #expect(runEnvironment.effectiveCredentialProjections.isEmpty)
        #expect(workspaceEnvironment.effectiveCredentialProjections.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.statusMessage == "GCP credentials connected. Retry this task.")
        #expect(viewModel.credentialProjectionTitle == "GCP credentials ready")
        #expect(viewModel.credentialProjectionIsEnabled == false)

        let report = ExecutionEnvironmentCredentialReadinessService.evaluate(
            task: task,
            codeDirectory: root,
            homeDirectoryPath: home
        )
        #expect(report.state == .ready)
        #expect(!report.shouldBlockLaunch)
    }

    @MainActor
    @Test("Docker view model presents Dockerfile setup as an executable build action")
    func dockerViewModelPresentsDockerfileSetupAction() async throws {
        let root = try makeTempDir("docker-build-action")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dockerfile = (root as NSString).appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(toFile: dockerfile, atomically: true, encoding: .utf8)
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: FakeDockerImageInventory(result: .success([]))
        )
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()

        let expectedRequest = DockerImageBuildRequest(
            image: "\(repository):latest",
            dockerfilePath: dockerfile,
            sourcePath: root
        )
        let expectedCommand = "docker build -t \(repository):latest -f '\(dockerfile)' '\(root)'"
        #expect(viewModel.runnableCandidates.isEmpty)
        #expect(viewModel.environmentOptions.map(\.title) == ["Host"])
        #expect(viewModel.environmentPickerTitle == "Run new tasks in")
        #expect(viewModel.environmentPickerSubtitle == "Host - providers run directly on macOS")
        #expect(viewModel.setupActionTitle == "Build workspace image")
        #expect(viewModel.setupActionSubtitle == "Build \(repository):latest from this workspace Dockerfile.")
        #expect(viewModel.setupActionHelp == expectedCommand)
        #expect(viewModel.detectedSummary == nil)
        #expect(viewModel.buildRequest == expectedRequest)
        #expect(viewModel.buildCommand == expectedCommand)
    }

    @MainActor
    @Test("Docker environment picker copy explains draft and pinned scopes")
    func dockerEnvironmentPickerCopyExplainsTaskScope() async throws {
        let root = try makeTempDir("docker-picker-scope")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let imageName = "\(repository):latest"
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let draft = AgentTask(title: "Draft", goal: "Run", workspace: workspace)
        let draftViewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([
            DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:built")
        ])))
        draftViewModel.setWorkspaceForTesting(workspace, selectedTask: draft)

        await draftViewModel.refresh()

        #expect(draftViewModel.environmentPickerTitle == "Run this draft in")
        #expect(draftViewModel.environmentPickerHelp.contains("only this draft task"))
        #expect(draftViewModel.environmentOptions.allSatisfy { $0.isEnabled })
        draftViewModel.selectEnvironmentOption("image:\(imageName)")
        #expect(ExecutionEnvironmentStore.decode(draft.executionEnvironmentSnapshotJSON).image == imageName)

        let completed = AgentTask(title: "Completed", goal: "Run", workspace: workspace)
        completed.status = .completed
        let completedRun = TaskRun(task: completed)
        completedRun.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        let completedViewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([
            DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:built")
        ])))
        completedViewModel.setWorkspaceForTesting(workspace, selectedTask: completed)

        await completedViewModel.refresh()

        #expect(completedViewModel.environmentPickerTitle == "Pinned to")
        #expect(completedViewModel.canUseEnvironmentPicker)
        #expect(completedViewModel.environmentPickerHelp.contains("next retry snapshot"))
        #expect(completedViewModel.environmentOptions.map(\.isEnabled) == [true, true])
        completedViewModel.selectEnvironmentOption("image:\(imageName)")
        #expect(ExecutionEnvironmentStore.decode(completed.executionEnvironmentSnapshotJSON).image == imageName)
        #expect(ExecutionEnvironmentStore.decode(completedRun.executionEnvironmentSnapshotJSON).isHost)
        #expect(completedViewModel.statusMessage?.contains("Next retry will use") == true)
    }

    @MainActor
    @Test("Docker view model builds, refreshes, and selects the workspace image")
    func dockerViewModelBuildsRefreshesAndSelectsWorkspaceImage() async throws {
        let root = try makeTempDir("docker-build-select")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dockerfile = (root as NSString).appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(toFile: dockerfile, atomically: true, encoding: .utf8)
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let imageName = "\(repository):latest"
        let inventory = SequencedDockerImageInventory(results: [
            .success([]),
            .success([DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:built")])
        ])
        let builder = RecordingDockerImageBuilder(result: .success(DockerImageBuildSummary(image: imageName)))
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(imageInventory: inventory, imageBuilder: builder)
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()
        await viewModel.buildWorkspaceImage()

        let selected = ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        #expect(await builder.recordedRequests() == [
            DockerImageBuildRequest(image: imageName, dockerfilePath: dockerfile, sourcePath: root)
        ])
        #expect(selected.kind == .dockerImage)
        #expect(selected.image == imageName)
        #expect(viewModel.runnableCandidates.map(\.environment.image) == [imageName])
        #expect(viewModel.statusMessage == "Image built and selected")
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isBuildingImage == false)
    }

    @MainActor
    @Test("Docker view model builds pinned tasks without changing their environment")
    func dockerViewModelBuildsPinnedTaskWithoutChangingEnvironment() async throws {
        let root = try makeTempDir("docker-build-pinned")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "FROM scratch\n".write(
            toFile: (root as NSString).appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let imageName = "\(repository):latest"
        let inventory = SequencedDockerImageInventory(results: [
            .success([]),
            .success([DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:built")])
        ])
        let builder = RecordingDockerImageBuilder(result: .success(DockerImageBuildSummary(image: imageName)))
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Task", goal: "Run", workspace: workspace)
        task.status = .completed
        let viewModel = WorkspaceDockerViewModel(imageInventory: inventory, imageBuilder: builder)
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        await viewModel.refresh()
        await viewModel.buildWorkspaceImage()

        #expect(ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON).isHost)
        #expect(viewModel.selectedEnvironment.isHost)
        #expect(viewModel.statusMessage == "Image built. Select it under Pinned to for the next retry.")
        #expect(viewModel.errorMessage == nil)
    }

    @MainActor
    @Test("Docker view model reports build connection failures without raw socket copy")
    func dockerViewModelReportsBuildConnectionFailure() async throws {
        let root = try makeTempDir("docker-build-failure")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "FROM scratch\n".write(
            toFile: (root as NSString).appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let rawDetail = "failed to connect to the docker API at unix:///Users/alvaro/.docker/run/docker.sock"
        let builder = RecordingDockerImageBuilder(result: .failure(.unavailable(rawDetail)))
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: FakeDockerImageInventory(result: .success([])),
            imageBuilder: builder
        )
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()
        await viewModel.buildWorkspaceImage()

        #expect(viewModel.errorMessage == "Docker is not connected. Start Docker Desktop, then build again.")
        #expect(viewModel.imageInventoryIssue == rawDetail)
        #expect(viewModel.statusMessage == nil)
    }

    @MainActor
    @Test("Docker view model groups non-runnable compose and devcontainer detections")
    func dockerViewModelGroupsNonRunnableDetections() async throws {
        let root = try makeTempDir("docker-detected-sources")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "services: {}\n".write(
            toFile: (root as NSString).appendingPathComponent("compose.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let devcontainerDir = (root as NSString).appendingPathComponent(".devcontainer")
        try FileManager.default.createDirectory(atPath: devcontainerDir, withIntermediateDirectories: true)
        try "{}".write(
            toFile: (devcontainerDir as NSString).appendingPathComponent("devcontainer.json"),
            atomically: true,
            encoding: .utf8
        )
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([])))
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()

        #expect(viewModel.buildCommand == nil)
        #expect(viewModel.runnableCandidates.isEmpty)
        #expect(viewModel.detectedSummary == "Detected Compose, Dev Container")
    }

    @MainActor
    @Test("Docker view model keeps Docker API failures concise in the container panel")
    func dockerViewModelSummarizesDockerAPIFailure() async throws {
        let root = try makeTempDir("docker-api-failure")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "FROM scratch\n".write(
            toFile: (root as NSString).appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let detail = "failed to connect to the docker API at unix:///Users/alvaro/.docker/run/docker.sock"
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: FakeDockerImageInventory(result: .failure(.unavailable(detail)))
        )
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()

        #expect(viewModel.dockerIssueTitle == "Docker is not connected")
        #expect(viewModel.dockerIssueSubtitle == "Start Docker Desktop, then refresh.")
        #expect(viewModel.imageInventoryIssue == detail)
        #expect(viewModel.detectedSummary == nil)
    }

    @MainActor
    @Test("Docker view model blocks environment changes for historical tasks")
    func dockerViewModelBlocksHistoricalTaskChanges() async throws {
        let root = try makeTempDir("docker-viewmodel-block")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root)
        let task = AgentTask(title: "Task", goal: "Run", workspace: workspace)
        task.status = .completed
        let viewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([])))
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)
        let candidate = DockerWorkspaceCandidate(
            environment: WorkspaceExecutionEnvironment(
                id: "image:test",
                kind: .dockerImage,
                displayName: "Test Image",
                image: "astra/test"
            ),
            isRunnable: true,
            issue: nil
        )

        viewModel.selectCandidate(candidate)

        #expect(ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON).isHost)
        #expect(viewModel.errorMessage?.contains("pinned") == true)
    }

    private func makeBasePlan(
        currentDirectory: String,
        environment: [String: String] = [:]
    ) -> AgentRuntimeProcessLaunchPlan {
        AgentRuntimeProcessLaunchPlan(
            runtime: .claudeCode,
            executablePath: "/host/claude",
            arguments: ["--print"],
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: false,
            commandPlannedFields: ["provider": "host"]
        )
    }

    private func makeTempDir(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func writeBigQueryDBTProfile(in root: String) throws {
        let dbt = (root as NSString).appendingPathComponent("dbt")
        try FileManager.default.createDirectory(atPath: dbt, withIntermediateDirectories: true)
        try """
        pedsnet:
          target: local
          outputs:
            local:
              type: bigquery
              method: oauth
              project: som-rit-phi-starr-dev
              dataset: root
        """.write(
            toFile: (dbt as NSString).appendingPathComponent("profiles.yml"),
            atomically: true,
            encoding: .utf8
        )
    }

    @discardableResult
    private func writeADCFile(inHome home: String) throws -> String {
        let gcloudDirectory = (home as NSString).appendingPathComponent(".config/gcloud")
        try FileManager.default.createDirectory(atPath: gcloudDirectory, withIntermediateDirectories: true)
        try "{}".write(
            toFile: (gcloudDirectory as NSString)
                .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName),
            atomically: true,
            encoding: .utf8
        )
        return gcloudDirectory
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }

    private func jsonArray(_ json: String?) throws -> [[String: Any]] {
        let data = try #require(json?.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func jsonDictionary(_ json: String?) throws -> [String: Any] {
        let data = try #require(json?.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor RecordingDockerRunner: BinaryRunner {
    struct Call: Equatable {
        var path: String
        var args: [String]
        var timeout: TimeInterval
    }

    private var results: [RunResult]
    private var calls: [Call] = []

    init(results: [RunResult]) {
        self.results = results
    }

    func recordedCalls() -> [Call] {
        calls
    }

    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await record(path: path, args: args, timeout: timeout)
    }

    private func record(path: String, args: [String], timeout: TimeInterval) -> RunResult {
        calls.append(Call(path: path, args: args, timeout: timeout))
        guard !results.isEmpty else {
            return .exited(code: 127, stdout: "", stderr: "no docker runner result configured")
        }
        return results.removeFirst()
    }
}

private actor RecordingDockerImageBuilder: DockerImageBuilding {
    private let result: Result<DockerImageBuildSummary, DockerImageBuildError>
    private var requests: [DockerImageBuildRequest] = []

    init(result: Result<DockerImageBuildSummary, DockerImageBuildError>) {
        self.result = result
    }

    func recordedRequests() -> [DockerImageBuildRequest] {
        requests
    }

    func buildImage(_ request: DockerImageBuildRequest) async -> Result<DockerImageBuildSummary, DockerImageBuildError> {
        requests.append(request)
        return result
    }
}

private actor SequencedDockerImageInventory: DockerImageInventoryListing {
    private var results: [Result<[DockerImageReference], DockerImageInventoryError>]

    init(results: [Result<[DockerImageReference], DockerImageInventoryError>]) {
        self.results = results
    }

    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
        guard !results.isEmpty else { return .success([]) }
        return results.removeFirst()
    }
}

private struct FakeDockerImageInventory: DockerImageInventoryListing {
    var result: Result<[DockerImageReference], DockerImageInventoryError>

    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
        result
    }
}

private extension Result where Failure == DockerExecutionPlanningError {
    var failure: DockerExecutionPlanningError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private extension Result where Failure == DockerImageAvailabilityError {
    var failure: DockerImageAvailabilityError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
