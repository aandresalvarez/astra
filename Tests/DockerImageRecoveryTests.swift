import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Docker image readiness and recovery")
struct DockerImageRecoveryTests {
    @Test("Readiness distinguishes a listed tag that exact-reference inspect cannot resolve")
    func readinessDistinguishesBrokenTagIndex() async {
        let image = "astra-starr-data-lake:latest"
        let imageID = "sha256:" + String(repeating: "a", count: 64)
        let availability = RecoverySequencedAvailability(results: [
            .failure(.missingImage(image)),
            .success(DockerImageAvailability(image: imageID, imageID: imageID))
        ])
        let service = DockerImageReadinessService(
            inventory: RecoveryImageInventory(result: .success([
                DockerImageReference(repository: "astra-starr-data-lake", tag: "latest", imageID: imageID)
            ])),
            availability: availability
        )

        let readiness = await service.checkImageReadiness(image)

        #expect(readiness.state == .listedButUnresolvable)
        #expect(readiness.imageID == imageID)
        #expect(readiness.detail.contains("cannot resolve"))
        #expect(await availability.checkedImages() == [image, imageID])
    }

    @Test("Readiness preserves inventory daemon failures during missing-image diagnosis")
    func readinessPreservesInventoryFailure() async {
        let image = "astra-starr-data-lake:latest"
        let service = DockerImageReadinessService(
            inventory: RecoveryImageInventory(result: .failure(.unavailable("Docker Desktop is not responding."))),
            availability: RecoverySequencedAvailability(results: [.failure(.missingImage(image))])
        )

        let readiness = await service.checkImageReadiness(image)

        #expect(readiness.state == .daemonUnavailable)
        #expect(readiness.detail == "Docker Desktop is not responding.")
    }

    @Test("Recovery retags only a verified image ID and verifies before succeeding")
    func recoveryRetagsAndVerifies() async throws {
        let image = "astra-starr-data-lake:latest"
        let imageID = "sha256:" + String(repeating: "b", count: 64)
        let readiness = RecoverySequencedReadiness(results: [
            DockerImageReadiness(
                image: image,
                state: .listedButUnresolvable,
                imageID: imageID,
                detail: "Docker lists the tag but cannot resolve it."
            ),
            DockerImageReadiness(image: image, state: .ready, imageID: imageID, detail: "ready")
        ])
        let tagger = RecoveryRecordingTagger(result: .success(()))
        let service = DockerImageRecoveryService(
            readiness: readiness,
            tagger: tagger,
            builder: RecoveryRecordingBuilder(result: .failure(.failed("unused")))
        )

        let plan = try await service.recoveryPlan(
            image: image,
            workspace: DockerImageRecoveryWorkspace(primaryPath: "/tmp/project", additionalPaths: [])
        ).get()
        #expect(plan.action == .retag(imageID: imageID))
        #expect(await tagger.recordedTags().isEmpty)

        try await service.performRecovery(plan).get()

        #expect(await tagger.recordedTags() == [.init(imageID: imageID, image: image)])
        #expect(await readiness.checkedImages() == [image, image])
    }

    @Test("Tag repair passes validated identifiers as separate process arguments")
    func tagRepairUsesStructuredArguments() async throws {
        let image = "astra-starr-data-lake:latest"
        let imageID = "sha256:" + String(repeating: "d", count: 64)
        let runner = RecoveryRecordingRunner(results: [
            .exited(code: 0, stdout: "desktop-linux\n", stderr: ""),
            .exited(code: 0, stdout: "", stderr: "")
        ])
        let tagger = DockerImageTagService(
            runner: runner,
            environmentProvider: { [:] },
            resolveDockerRuntime: {
                DockerRuntimeResolver.resolution(executablePath: "/usr/local/bin/docker", environment: $0)
            }
        )

        try await tagger.tagImage(imageID: imageID, as: image).get()

        #expect(await runner.recordedCalls().map(\.args) == [
            ["context", "show"],
            ["image", "tag", imageID, image]
        ])
    }

    @Test("Tag repair rejects unsafe identifiers before launching Docker")
    func tagRepairRejectsUnsafeIdentifiers() async {
        let runner = RecoveryRecordingRunner(results: [])
        let tagger = DockerImageTagService(
            runner: runner,
            environmentProvider: { [:] },
            resolveDockerRuntime: {
                DockerRuntimeResolver.resolution(executablePath: "/usr/local/bin/docker", environment: $0)
            }
        )

        let result = await tagger.tagImage(
            imageID: "sha256:abc;docker system prune",
            as: "astra-starr-data-lake:latest"
        )

        guard case .failure(.invalidImageID) = result else {
            Issue.record("Expected unsafe image ID to be rejected")
            return
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("Recovery refuses success when post-repair verification still fails")
    func recoveryFailsClosedAfterUnverifiedRepair() async throws {
        let image = "astra-starr-data-lake:latest"
        let imageID = "sha256:" + String(repeating: "c", count: 64)
        let readiness = RecoverySequencedReadiness(results: [
            DockerImageReadiness(image: image, state: .listedButUnresolvable, imageID: imageID, detail: "broken tag"),
            DockerImageReadiness(image: image, state: .listedButUnresolvable, imageID: imageID, detail: "still broken")
        ])
        let service = DockerImageRecoveryService(
            readiness: readiness,
            tagger: RecoveryRecordingTagger(result: .success(())),
            builder: RecoveryRecordingBuilder(result: .failure(.failed("unused")))
        )
        let plan = try await service.recoveryPlan(
            image: image,
            workspace: DockerImageRecoveryWorkspace(primaryPath: "/tmp/project", additionalPaths: [])
        ).get()

        guard case .failure(.verificationFailed(let detail)) = await service.performRecovery(plan) else {
            Issue.record("Expected post-repair verification to fail closed")
            return
        }
        #expect(detail.contains("still failed launch verification"))
    }

    @Test("Recovery rebuilds a missing generated image only from its matching workspace Dockerfile")
    func recoveryPlansMatchingWorkspaceBuild() async throws {
        let root = try makeTempDir("docker-recovery-build")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dockerfile = (root as NSString).appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(toFile: dockerfile, atomically: true, encoding: .utf8)
        let image = "\(DockerWorkspaceDiscoveryService.generatedImageName(for: root)):latest"
        let readiness = RecoverySequencedReadiness(results: [
            DockerImageReadiness(image: image, state: .missing, imageID: nil, detail: "missing"),
            DockerImageReadiness(image: image, state: .ready, imageID: "sha256:built", detail: "ready")
        ])
        let builder = RecoveryRecordingBuilder(result: .success(DockerImageBuildSummary(image: image)))
        let service = DockerImageRecoveryService(
            readiness: readiness,
            tagger: RecoveryRecordingTagger(result: .failure(.tagFailed("unused"))),
            builder: builder
        )

        let plan = try await service.recoveryPlan(
            image: image,
            workspace: DockerImageRecoveryWorkspace(primaryPath: root, additionalPaths: [])
        ).get()
        #expect(plan.action == .rebuild(DockerImageBuildRequest(
            image: image,
            dockerfilePath: dockerfile,
            sourcePath: root
        )))

        try await service.performRecovery(plan).get()
        #expect(await builder.recordedRequests().count == 1)
    }

    @Test("Recovery canonicalizes an untagged requested image reference")
    func recoveryMatchesUntaggedRequestedImage() async throws {
        let root = try makeTempDir("docker-recovery-untagged")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dockerfile = (root as NSString).appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(toFile: dockerfile, atomically: true, encoding: .utf8)
        let image = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let service = DockerImageRecoveryService(
            readiness: RecoveryFixedReadiness(readiness: DockerImageReadiness(
                image: image, state: .missing, imageID: nil, detail: "missing"
            )),
            tagger: RecoveryRecordingTagger(result: .failure(.tagFailed("unused"))),
            builder: RecoveryRecordingBuilder(result: .failure(.failed("unused")))
        )

        let plan = try await service.recoveryPlan(
            image: image,
            workspace: DockerImageRecoveryWorkspace(primaryPath: root, additionalPaths: [])
        ).get()

        #expect(plan.action == .rebuild(DockerImageBuildRequest(
            image: image,
            dockerfilePath: dockerfile,
            sourcePath: root
        )))
    }

    @Test("Recovery refuses ambiguous rebuild roots and honors the failed run source path")
    func recoveryDisambiguatesMatchingWorkspaceBuilds() async throws {
        let root = try makeTempDir("docker-recovery-ambiguous")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = (root as NSString).appendingPathComponent("one/shared")
        let second = (root as NSString).appendingPathComponent("two/shared")
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        try "FROM scratch\n".write(toFile: (first as NSString).appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try "FROM scratch\n".write(toFile: (second as NSString).appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        let image = "\(DockerWorkspaceDiscoveryService.generatedImageName(for: first)):latest"
        let service = DockerImageRecoveryService(
            readiness: RecoveryFixedReadiness(readiness: DockerImageReadiness(
                image: image, state: .missing, imageID: nil, detail: "missing"
            )),
            tagger: RecoveryRecordingTagger(result: .failure(.tagFailed("unused"))),
            builder: RecoveryRecordingBuilder(result: .failure(.failed("unused")))
        )

        let ambiguous = await service.recoveryPlan(
            image: image,
            workspace: DockerImageRecoveryWorkspace(primaryPath: first, additionalPaths: [second])
        )
        guard case .failure(.notRecoverable(let detail)) = ambiguous else {
            Issue.record("Expected ambiguous matching Dockerfiles to be rejected")
            return
        }
        #expect(detail.contains("multiple workspace Dockerfiles"))

        let selected = try await service.recoveryPlan(
            image: image,
            workspace: DockerImageRecoveryWorkspace(
                primaryPath: first,
                additionalPaths: [second],
                preferredSourcePath: second
            )
        ).get()
        #expect(selected.action == .rebuild(DockerImageBuildRequest(
            image: image,
            dockerfilePath: (second as NSString).appendingPathComponent("Dockerfile"),
            sourcePath: second
        )))
    }

    @MainActor
    @Test("Coordinator keeps Docker off-main and aborts when authorization is not durable")
    func coordinatorFailsClosedBeforeDockerMutation() async throws {
        let fixture = try makeCoordinatorFixture()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let recovery = RecoveryCoordinatorService(plan: .success(plan), perform: .success(()))
        let recorder = RecoveryCoordinatorEventRecorder(results: [false])
        let coordinator = DockerImageRecoveryCoordinator(recovery: recovery, eventRecorder: recorder)

        coordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { !coordinator.isBusy })
        #expect(await recovery.planRanOnMainThread() == false)

        coordinator.perform(plan, task: fixture.task, run: fixture.run, modelContext: fixture.context) {}

        #expect(await recovery.performCallCount() == 0)
        #expect(coordinator.errorMessage?.contains("no Docker command was run") == true)
    }

    @MainActor
    @Test("Coordinator does not retry after an unpersisted success or a stale run")
    func coordinatorRequiresDurableCurrentSuccessBeforeRetry() async throws {
        let fixture = try makeCoordinatorFixture()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let recovery = RecoveryCoordinatorService(
            plan: .success(plan),
            perform: .success(()),
            performDelayNanoseconds: 30_000_000
        )
        let recorder = RecoveryCoordinatorEventRecorder(results: [true, true])
        let coordinator = DockerImageRecoveryCoordinator(recovery: recovery, eventRecorder: recorder)
        var retried = false

        coordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { !coordinator.isBusy })
        coordinator.perform(plan, task: fixture.task, run: fixture.run, modelContext: fixture.context) { retried = true }
        coordinator.invalidateIfRunChanged(for: UUID(), to: UUID())
        #expect(coordinator.isBusy)
        coordinator.invalidateIfRunChanged(for: fixture.task.id, to: UUID())
        #expect(await waitUntil { !coordinator.isBusy })

        #expect(await recovery.performRanOnMainThread() == false)
        #expect(!retried)
        #expect(recorder.recordedResults == [.started, .failed])

        let unpersistedSuccessRecorder = RecoveryCoordinatorEventRecorder(results: [true, false])
        let secondCoordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(plan: .success(plan), perform: .success(())),
            eventRecorder: unpersistedSuccessRecorder
        )
        secondCoordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { !secondCoordinator.isBusy })
        secondCoordinator.perform(plan, task: fixture.task, run: fixture.run, modelContext: fixture.context) { retried = true }
        #expect(await waitUntil { !secondCoordinator.isBusy })
        #expect(!retried)
        #expect(secondCoordinator.errorMessage?.contains("task was not retried") == true)
    }

    @MainActor
    @Test("Invalidated recovery reports a terminal event persistence failure")
    func invalidatedRecoveryReportsEventPersistenceFailure() async throws {
        let fixture = try makeCoordinatorFixture()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let recorder = RecoveryCoordinatorEventRecorder(results: [true, false])
        let coordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(
                plan: .success(plan),
                perform: .success(()),
                performDelayNanoseconds: 30_000_000
            ),
            eventRecorder: recorder
        )

        coordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { !coordinator.isBusy })
        coordinator.perform(plan, task: fixture.task, run: fixture.run, modelContext: fixture.context) {}
        coordinator.invalidateIfTaskDeleted(fixture.task.id)

        #expect(await waitUntil { !coordinator.isBusy })
        #expect(coordinator.errorMessage?.contains("could not durably record") == true)
        #expect(recorder.recordedResults == [.started, .failed])
    }

    @MainActor
    @Test("Coordinator completes durable recovery after its task view is released")
    func coordinatorCompletesAfterViewRelease() async throws {
        let fixture = try makeCoordinatorFixture()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let recorder = RecoveryCoordinatorEventRecorder(results: [true, true])
        var coordinator: DockerImageRecoveryCoordinator? = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(
                plan: .success(plan),
                perform: .success(()),
                performDelayNanoseconds: 30_000_000
            ),
            eventRecorder: recorder
        )
        var retried = false

        coordinator?.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { coordinator?.isBusy == false })
        coordinator?.perform(plan, task: fixture.task, run: fixture.run, modelContext: fixture.context) {
            retried = true
        }
        coordinator = nil

        #expect(await waitUntil { recorder.recordedResults.last == .succeeded })
        #expect(retried)
        #expect(recorder.recordedResults == [.started, .succeeded])
    }

    @MainActor
    @Test("Shared recovery state blocks task retries while Docker work is active")
    func sharedRecoveryStateBlocksTaskRetries() {
        let coordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(plan: .failure(.notRecoverable("unused")), perform: .success(())),
            eventRecorder: RecoveryCoordinatorEventRecorder(results: [])
        )

        #expect(coordinator.canStartTaskRetry)
        coordinator.isBusy = true
        #expect(!coordinator.canStartTaskRetry)
    }

    @MainActor
    @Test("Recovery retry lock only blocks the originating task")
    func recoveryBusyStateIsTaskScoped() async throws {
        let fixture = try makeCoordinatorFixture()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let coordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(
                plan: .success(plan),
                perform: .success(()),
                performDelayNanoseconds: 30_000_000
            ),
            eventRecorder: RecoveryCoordinatorEventRecorder(results: [true, true])
        )

        coordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { !coordinator.isBusy })
        coordinator.perform(plan, task: fixture.task, run: fixture.run, modelContext: fixture.context) {}

        #expect(coordinator.isBusy(for: fixture.task.id))
        #expect(!coordinator.canStartTaskRetry(for: fixture.task.id))
        #expect(coordinator.canStartTaskRetry(for: UUID()))
        #expect(await waitUntil { !coordinator.isBusy })
    }

    @MainActor
    @Test("Recovery errors remain scoped to the originating task")
    func recoveryErrorStateIsTaskScoped() async throws {
        let fixture = try makeCoordinatorFixture()
        let coordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(
                plan: .failure(.notRecoverable("Dockerfile unavailable")),
                perform: .success(())
            ),
            eventRecorder: RecoveryCoordinatorEventRecorder(results: [])
        )

        coordinator.prepare(
            image: "astra-project:latest",
            workspace: fixture.workspace,
            taskID: fixture.task.id,
            run: fixture.run
        )
        #expect(await waitUntil { !coordinator.isBusy })
        #expect(coordinator.isErrorVisible(for: fixture.task.id))
        #expect(!coordinator.isErrorVisible(for: UUID()))
        coordinator.dismissError(for: UUID())
        #expect(coordinator.isErrorVisible(for: fixture.task.id))
        coordinator.dismissError(for: fixture.task.id)
        #expect(!coordinator.isErrorVisible(for: fixture.task.id))
    }

    @MainActor
    @Test("Recovery invalidation removes deleted task dialogs and prevents retry")
    func recoveryInvalidatesDeletedTask() async throws {
        let fixture = try makeCoordinatorFixture()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let coordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(plan: .success(plan), perform: .success(())),
            eventRecorder: RecoveryCoordinatorEventRecorder(results: [])
        )

        coordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { coordinator.isConfirmationVisible(for: fixture.task.id) })
        coordinator.invalidateIfTaskDeleted(fixture.task.id)

        #expect(coordinator.pendingPlan == nil)
        #expect(!coordinator.isConfirmationVisible(for: fixture.task.id))
        #expect(coordinator.canStartTaskRetry)
    }

    @MainActor
    @Test("Recovery confirmation remains scoped to its originating task")
    func recoveryConfirmationIsTaskScoped() async throws {
        let fixture = try makeCoordinatorFixture()
        let otherTaskID = UUID()
        let plan = DockerImageRecoveryPlan(
            image: "astra-project:latest",
            action: .retryOnly,
            title: "Ready",
            confirmation: "Retry",
            auditAction: "retry_only"
        )
        let coordinator = DockerImageRecoveryCoordinator(
            recovery: RecoveryCoordinatorService(plan: .success(plan), perform: .success(())),
            eventRecorder: RecoveryCoordinatorEventRecorder(results: [])
        )

        coordinator.prepare(image: plan.image, workspace: fixture.workspace, taskID: fixture.task.id, run: fixture.run)
        #expect(await waitUntil { coordinator.isConfirmationVisible(for: fixture.task.id) })
        #expect(!coordinator.isConfirmationVisible(for: otherTaskID))
        #expect(coordinator.pendingTaskID == fixture.task.id)
    }

    @Test("Invalid Docker references do not offer image repair")
    func invalidDockerReferenceDoesNotOfferRepair() {
        #expect(DockerImageRecoveryPresentation.image(
            stopReason: TaskRunStopReason.dockerImageUnavailable.rawValue,
            launchBlockImage: "astra project",
            launchBlockReadinessState: DockerImageReadinessState.invalidReference.rawValue,
            runID: nil,
            runs: []
        ) == nil)
        #expect(DockerImageRecoveryPresentation.image(
            stopReason: TaskRunStopReason.dockerImageUnavailable.rawValue,
            launchBlockImage: "astra-project:latest",
            launchBlockReadinessState: DockerImageReadinessState.missing.rawValue,
            runID: nil,
            runs: []
        ) == "astra-project:latest")
    }

    @MainActor
    @Test("Container view model never promotes a listed but unresolvable image")
    func viewModelRejectsUnresolvableListedImage() async throws {
        let root = try makeTempDir("docker-viewmodel-unresolvable")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let image = "\(repository):latest"
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: RecoveryImageInventory(result: .success([
                DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:abc")
            ])),
            imageReadiness: RecoveryFixedReadiness(readiness: DockerImageReadiness(
                image: image,
                state: .listedButUnresolvable,
                imageID: "sha256:abc",
                detail: "Docker lists \(image), but cannot resolve that tag."
            ))
        )
        viewModel.setWorkspaceForTesting(Workspace(name: "Docker", primaryPath: root))

        await viewModel.refresh()

        #expect(viewModel.runnableCandidates.isEmpty)
        #expect(viewModel.environmentOptions.map(\.title) == ["Host"])
        #expect(viewModel.dockerIssueTitle == "Docker image is not runnable")
        #expect(viewModel.dockerIssueSubtitle?.contains("cannot resolve") == true)
    }

    @MainActor
    @Test("Container view model validates image readiness off the main actor")
    func viewModelValidatesReadinessOffMainActor() async throws {
        let root = try makeTempDir("docker-viewmodel-off-main")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "FROM scratch\n".write(
            toFile: (root as NSString).appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let repository = DockerWorkspaceDiscoveryService.generatedImageName(for: root)
        let image = "\(repository):latest"
        let readiness = RecoveryThreadRecordingReadiness(
            result: DockerImageReadiness(image: image, state: .ready, imageID: "sha256:ready", detail: "ready")
        )
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: RecoveryImageInventory(result: .success([
                DockerImageReference(repository: repository, tag: "latest", imageID: "sha256:ready")
            ])),
            imageReadiness: readiness
        )
        viewModel.setWorkspaceForTesting(Workspace(name: "Docker", primaryPath: root))

        await viewModel.refresh()

        #expect(await readiness.mainThreadObservations() == [false])
        #expect(viewModel.runnableCandidates.map(\.environment.image) == [image])
    }

    @MainActor
    @Test("Container view model hides unrelated image failures when a runnable image exists")
    func viewModelHidesUnselectedImageFailure() {
        let broken = DockerWorkspaceCandidate(
            environment: WorkspaceExecutionEnvironment(
                id: "image:broken",
                kind: .dockerImage,
                displayName: "Broken Image",
                image: "astra-broken:latest"
            ),
            isRunnable: false,
            issue: "Docker cannot resolve this image."
        )
        let ready = DockerWorkspaceCandidate(
            environment: WorkspaceExecutionEnvironment(
                id: "image:ready",
                kind: .dockerImage,
                displayName: "Ready Image",
                image: "astra-ready:latest"
            ),
            isRunnable: true,
            issue: nil
        )
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: RecoveryImageInventory(result: .success([]))
        )
        viewModel.candidates = [broken, ready]

        #expect(viewModel.dockerIssueTitle == nil)
        #expect(viewModel.dockerIssueSubtitle == nil)
        viewModel.selectedEnvironment = broken.environment
        #expect(viewModel.dockerIssueTitle == "Docker image is not runnable")
    }

    private func makeTempDir(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @MainActor
    private func makeCoordinatorFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        workspace: Workspace,
        task: AgentTask,
        run: TaskRun
    ) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Docker", primaryPath: "/tmp/project")
        let task = AgentTask(title: "Repair", goal: "Retry safely", workspace: workspace)
        let run = TaskRun(task: task)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(
            WorkspaceExecutionEnvironment(
                id: "dockerfile:/tmp/project/Dockerfile",
                kind: .dockerfile,
                displayName: "Project Dockerfile",
                sourcePath: "/tmp/project",
                image: "astra-project:latest",
                dockerfilePath: "/tmp/project/Dockerfile"
            )
        )
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        return (container, context, workspace, task, run)
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
}

private struct RecoveryImageInventory: DockerImageInventoryListing {
    let result: Result<[DockerImageReference], DockerImageInventoryError>
    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> { result }
}

private struct RecoveryFixedReadiness: DockerImageReadinessChecking {
    let readiness: DockerImageReadiness
    func checkImageReadiness(_ image: String) async -> DockerImageReadiness { readiness }
}

private actor RecoveryThreadRecordingReadiness: DockerImageReadinessChecking {
    private let result: DockerImageReadiness
    private var observations: [Bool] = []

    init(result: DockerImageReadiness) {
        self.result = result
    }

    func mainThreadObservations() -> [Bool] { observations }

    func checkImageReadiness(_ image: String) async -> DockerImageReadiness {
        observations.append(recoveryThreadIsMain())
        return result
    }
}

private actor RecoverySequencedAvailability: DockerImageAvailabilityChecking {
    private var results: [Result<DockerImageAvailability, DockerImageAvailabilityError>]
    private var images: [String] = []
    init(results: [Result<DockerImageAvailability, DockerImageAvailabilityError>]) { self.results = results }
    func checkedImages() -> [String] { images }
    func checkImageAvailability(_ image: String) async -> Result<DockerImageAvailability, DockerImageAvailabilityError> {
        images.append(image)
        return results.isEmpty ? .failure(.unavailable("no readiness result configured")) : results.removeFirst()
    }
}

private actor RecoverySequencedReadiness: DockerImageReadinessChecking {
    private var results: [DockerImageReadiness]
    private var images: [String] = []
    init(results: [DockerImageReadiness]) { self.results = results }
    func checkedImages() -> [String] { images }
    func checkImageReadiness(_ image: String) async -> DockerImageReadiness {
        images.append(image)
        return results.isEmpty
            ? DockerImageReadiness(image: image, state: .missing, imageID: nil, detail: "no readiness result configured")
            : results.removeFirst()
    }
}

private actor RecoveryRecordingTagger: DockerImageTagging {
    struct Call: Equatable { let imageID: String; let image: String }
    private let result: Result<Void, DockerImageRecoveryError>
    private var calls: [Call] = []
    init(result: Result<Void, DockerImageRecoveryError>) { self.result = result }
    func recordedTags() -> [Call] { calls }
    func tagImage(imageID: String, as image: String) async -> Result<Void, DockerImageRecoveryError> {
        calls.append(Call(imageID: imageID, image: image))
        return result
    }
}

private actor RecoveryRecordingBuilder: DockerImageBuilding {
    private let result: Result<DockerImageBuildSummary, DockerImageBuildError>
    private var requests: [DockerImageBuildRequest] = []
    init(result: Result<DockerImageBuildSummary, DockerImageBuildError>) { self.result = result }
    func recordedRequests() -> [DockerImageBuildRequest] { requests }
    func buildImage(_ request: DockerImageBuildRequest) async -> Result<DockerImageBuildSummary, DockerImageBuildError> {
        requests.append(request)
        return result
    }
}

private actor RecoveryRecordingRunner: BinaryRunner {
    struct Call: Equatable { let path: String; let args: [String]; let timeout: TimeInterval }
    private var results: [RunResult]
    private var calls: [Call] = []
    init(results: [RunResult]) { self.results = results }
    func recordedCalls() -> [Call] { calls }
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
        return results.isEmpty
            ? .exited(code: 127, stdout: "", stderr: "no docker runner result configured")
            : results.removeFirst()
    }
}

private actor RecoveryCoordinatorService: DockerImageRecovering {
    private let plan: Result<DockerImageRecoveryPlan, DockerImageRecoveryError>
    private let performResult: Result<Void, DockerImageRecoveryError>
    private let performDelayNanoseconds: UInt64
    private var planOnMainThread: Bool?
    private var performOnMainThread: Bool?
    private var performCalls = 0

    init(
        plan: Result<DockerImageRecoveryPlan, DockerImageRecoveryError>,
        perform: Result<Void, DockerImageRecoveryError>,
        performDelayNanoseconds: UInt64 = 0
    ) {
        self.plan = plan
        self.performResult = perform
        self.performDelayNanoseconds = performDelayNanoseconds
    }

    func recoveryPlan(
        image: String,
        workspace: DockerImageRecoveryWorkspace
    ) async -> Result<DockerImageRecoveryPlan, DockerImageRecoveryError> {
        planOnMainThread = recoveryThreadIsMain()
        return plan
    }

    func performRecovery(_ plan: DockerImageRecoveryPlan) async -> Result<Void, DockerImageRecoveryError> {
        performCalls += 1
        performOnMainThread = recoveryThreadIsMain()
        if performDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: performDelayNanoseconds)
        }
        return performResult
    }

    func planRanOnMainThread() -> Bool? { planOnMainThread }
    func performRanOnMainThread() -> Bool? { performOnMainThread }
    func performCallCount() -> Int { performCalls }
}

private func recoveryThreadIsMain() -> Bool { Thread.isMainThread }

@MainActor
private final class RecoveryCoordinatorEventRecorder: DockerImageRecoveryEventRecording {
    private var results: [Bool]
    private(set) var recordedResults: [DockerImageRecoveryEventPayload.Result] = []

    init(results: [Bool]) {
        self.results = results
    }

    func record(
        task: AgentTask,
        run: TaskRun?,
        plan: DockerImageRecoveryPlan,
        result: DockerImageRecoveryEventPayload.Result,
        detail: String?,
        modelContext: ModelContext
    ) -> Bool {
        recordedResults.append(result)
        return results.isEmpty ? true : results.removeFirst()
    }
}
