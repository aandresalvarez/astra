import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Execution Environments")
struct ExecutionEnvironmentTests {
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
        #expect(plan.arguments.contains("/usr/local/bin/claude"))
        #expect(plan.arguments.contains("--workdir"))
        #expect(plan.arguments.contains("/workspace"))
        #expect(plan.environment["FOO"] == "bar")
        #expect(plan.environment["SECRET"] == nil)
        #expect(plan.pathMapper?.hostPath(forContainerPath: "/workspace/file.txt") == (root as NSString).appendingPathComponent("file.txt"))
        #expect(plan.commandPlannedFields["os_sandbox_claim"] == "false")
        #expect(plan.commandPlannedFields["container_executable_source"] == "environment")
        #expect(plan.commandPlannedFields["container_image"] == "astra/test:latest")
        #expect(plan.commandPlannedFields["container_workdir"] == "/workspace")
        #expect(plan.commandPlannedFields["container_executable"] == "/usr/local/bin/claude")
        #expect(plan.commandPlannedFields["container_mount_summary"]?.contains("\(root)=/workspace") == true)
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
            image: "astra/test:latest"
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
            image: "astra-starr-data-lake:latest"
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
            environmentKeyAllowlist: ["TOKEN_NAME"]
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
        #expect(viewModel.environmentPickerSubtitle == "\(URL(fileURLWithPath: root).lastPathComponent) Image - \(repository):latest")
        #expect(viewModel.environmentPickerHelp.contains("docker run using \(repository):latest"))
        #expect(viewModel.environmentOptions.map(\.isSelected) == [false, true])
        #expect(AgentTask(title: "Task", goal: "Run", workspace: workspace).executionEnvironmentSnapshotJSON == workspace.activeExecutionEnvironmentJSON)
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
        let completedViewModel = WorkspaceDockerViewModel(imageInventory: FakeDockerImageInventory(result: .success([
            DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:built")
        ])))
        completedViewModel.setWorkspaceForTesting(workspace, selectedTask: completed)

        await completedViewModel.refresh()

        #expect(completedViewModel.environmentPickerTitle == "Pinned to")
        #expect(completedViewModel.environmentPickerHelp.contains("already has execution history"))
        #expect(completedViewModel.environmentOptions.allSatisfy { !$0.isEnabled })
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

        #expect(task.executionEnvironmentSnapshotJSON == nil)
        #expect(viewModel.selectedEnvironment.isHost)
        #expect(viewModel.statusMessage == "Image built. Start a new task to use it.")
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

        #expect(task.executionEnvironmentSnapshotJSON == nil)
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

    private func makeContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
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
