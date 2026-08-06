import ASTRACore
import ASTRAModels
import Foundation
import Testing
@testable import ASTRA

@Suite("Docker CLI Resolution")
struct DockerCLIResolutionTests {
    @Test("Docker inventory refreshes the enriched environment at operation time")
    func inventoryRefreshesEnvironmentAfterShellProbe() async throws {
        let environment = DockerEnvironmentBox(["PATH": "/usr/bin:/bin"])
        let runner = DockerCLIRecordingRunner(results: [
            .exited(code: 0, stdout: "desktop-linux\n", stderr: ""),
            .exited(code: 0, stdout: "astra/test\tlatest\tsha256:123\n", stderr: "")
        ])
        let service = DockerImageInventoryService(
            runner: runner,
            environmentProvider: { environment.value },
            resolveDockerRuntime: { currentEnvironment in
                guard currentEnvironment["PATH"]?.contains("/nix/profile/bin") == true else {
                    return nil
                }
                return DockerRuntimeResolver.resolution(
                    executablePath: "/nix/profile/bin/docker",
                    environment: currentEnvironment
                )
            }
        )
        environment.value = ["PATH": "/nix/profile/bin:/usr/bin:/bin"]

        let images = try await service.listLoadedImages().get()

        #expect(images.map(\.name) == ["astra/test:latest"])
        let calls = await runner.recordedCalls()
        #expect(calls.map(\.path) == ["/nix/profile/bin/docker", "/nix/profile/bin/docker"])
        #expect(calls.allSatisfy { $0.environmentPath == "/nix/profile/bin:/usr/bin:/bin" })
    }

    @Test("Docker services bypass a production app's minimal PATH after resolving the CLI")
    func servicesUseResolvedExecutableWithMinimalApplicationPath() async throws {
        let runner = DockerCLIRecordingRunner(results: [
            .exited(code: 0, stdout: "desktop-linux\n", stderr: ""),
            .exited(code: 0, stdout: "built\n", stderr: "")
        ])
        let service = DockerImageBuildService(
            runner: runner,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            resolveDockerRuntime: {
                DockerRuntimeResolver.resolution(
                    executablePath: "/Applications/Docker.app/Contents/Resources/bin/docker",
                    environment: $0
                )
            }
        )

        let result = await service.buildImage(DockerImageBuildRequest(
            image: "astra-production-path:latest",
            dockerfilePath: "/tmp/demo/Dockerfile",
            sourcePath: "/tmp/demo"
        ))

        #expect(try result.get().image == "astra-production-path:latest")
        let calls = await runner.recordedCalls()
        let bundledDirectory = "/Applications/Docker.app/Contents/Resources/bin"
        #expect(calls.map(\.path) == ["\(bundledDirectory)/docker", "\(bundledDirectory)/docker"])
        #expect(calls.allSatisfy {
            $0.environmentPath == "\(bundledDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
        })
        #expect(calls.allSatisfy { $0.args.first != "docker" })
    }

    @Test("Docker build reports a missing CLI before attempting a process launch")
    func buildReportsMissingCLIWithoutLaunching() async {
        let runner = DockerCLIRecordingRunner(results: [])
        let service = DockerImageBuildService(
            runner: runner,
            environment: ["PATH": "/usr/bin:/bin"],
            resolveDockerRuntime: { _ in nil }
        )

        let result = await service.buildImage(DockerImageBuildRequest(
            image: "astra-missing:latest",
            dockerfilePath: "/tmp/demo/Dockerfile",
            sourcePath: "/tmp/demo"
        ))

        #expect(result == .failure(.cliMissing))
        #expect(await runner.recordedCalls().isEmpty)
    }

    @MainActor
    @Test("Docker UI distinguishes a missing CLI from a disconnected daemon")
    func viewModelPresentsMissingCLI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docker-cli-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "FROM scratch\n".write(
            to: root.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let workspace = Workspace(name: "Docker", primaryPath: root.path)
        let viewModel = WorkspaceDockerViewModel(
            imageInventory: MissingDockerCLIInventory()
        )
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()

        #expect(viewModel.dockerIssueTitle == "Docker CLI was not found")
        #expect(viewModel.dockerIssueSubtitle == "Install or reopen Docker Desktop, then refresh.")
        #expect(viewModel.imageInventoryIssue == "Docker CLI was not found. Install or reopen Docker Desktop, then refresh.")
    }

    @MainActor
    @Test("Docker UI remediation covers a DOCKER_HOST override")
    func viewModelPresentsDockerHostRemediation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docker-host-remediation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Docker", primaryPath: root.path)
        let viewModel = WorkspaceDockerViewModel(imageInventory: UnsafeRemoteDockerInventory())
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.refresh()

        #expect(viewModel.dockerIssueTitle == "Docker context needs approval")
        #expect(viewModel.dockerIssueSubtitle == "Switch to a local Docker context and unset DOCKER_HOST, then refresh.")
    }
}

private final class DockerEnvironmentBox: @unchecked Sendable {
    var value: [String: String]

    init(_ value: [String: String]) {
        self.value = value
    }
}

private actor DockerCLIRecordingRunner: BinaryRunner {
    struct Call: Equatable {
        var path: String
        var args: [String]
        var environmentPath: String?
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
        await record(path: path, args: args, environmentPath: environment?["PATH"])
    }

    private func record(path: String, args: [String], environmentPath: String?) -> RunResult {
        calls.append(Call(path: path, args: args, environmentPath: environmentPath))
        guard !results.isEmpty else {
            return .exited(code: 127, stdout: "", stderr: "unexpected Docker process launch")
        }
        return results.removeFirst()
    }
}

private struct MissingDockerCLIInventory: DockerImageInventoryListing {
    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
        .failure(.cliMissing)
    }
}

private struct UnsafeRemoteDockerInventory: DockerImageInventoryListing {
    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
        .failure(.unsafeRemoteContext("Remote Docker host is not approved."))
    }
}
