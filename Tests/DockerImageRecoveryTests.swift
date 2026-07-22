import Foundation
import Testing
import ASTRACore
import ASTRAModels
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

    private func makeTempDir(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
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
