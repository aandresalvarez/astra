import Foundation
import Testing
import ASTRACore
import ASTRAModels

struct WorkspaceDockerViewModelTests {
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

private func recoveryThreadIsMain() -> Bool { Thread.isMainThread }
