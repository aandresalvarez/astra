import Foundation
import ASTRACore

struct DockerImageBuildRequest: Equatable, Sendable {
    var image: String
    var dockerfilePath: String
    var sourcePath: String
}

struct DockerImageBuildSummary: Equatable, Sendable {
    var image: String
}

enum DockerImageBuildError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case unsafeRemoteContext(String)
    case failed(String)
    case timedOut
    case cancelled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Docker is not connected. Start Docker Desktop, then build again."
        case .unsafeRemoteContext(let detail):
            return detail
        case .failed(let detail):
            return "Docker build failed. \(detail)"
        case .timedOut:
            return "Docker build timed out."
        case .cancelled:
            return "Docker build was cancelled."
        case .launchFailed(let detail):
            return "Docker could not start. \(detail)"
        }
    }
}

protocol DockerImageBuilding {
    func buildImage(_ request: DockerImageBuildRequest) async -> Result<DockerImageBuildSummary, DockerImageBuildError>
}

struct DockerImageBuildService: DockerImageBuilding {
    private let runner: any BinaryRunner
    private let environment: [String: String]
    private let timeout: TimeInterval

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 30 * 60
    ) {
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    func buildImage(_ request: DockerImageBuildRequest) async -> Result<DockerImageBuildSummary, DockerImageBuildError> {
        let contextResult = await runner.run(
            path: "/usr/bin/env",
            args: ["docker", "context", "show"],
            timeout: 3,
            environment: nil
        )
        let context = contextResult.isSuccess
            ? contextResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let readiness = DockerReadinessService.evaluate(
            dockerStatus: .healthy(path: "docker", version: ""),
            dockerContext: context,
            dockerHost: environment["DOCKER_HOST"]
        )
        guard readiness.state != .unsafeRemoteContext else {
            return .failure(.unsafeRemoteContext(readiness.issue ?? "Docker is using a remote context."))
        }

        let result = await runner.run(
            path: "/usr/bin/env",
            args: ["docker", "build", "-t", request.image, "-f", request.dockerfilePath, request.sourcePath],
            timeout: timeout,
            environment: nil
        )
        guard result.isSuccess else {
            return .failure(Self.error(from: result))
        }
        return .success(DockerImageBuildSummary(image: request.image))
    }

    private static func error(from result: RunResult) -> DockerImageBuildError {
        switch result.outcome {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .launchFailed:
            return .launchFailed(shortDetail(result.launchError ?? "Launch failed."))
        case .exited:
            let detail = shortDetail(result.stderr.isEmpty ? result.stdout : result.stderr)
            if looksLikeDockerUnavailable(detail) {
                return .unavailable(detail)
            }
            return .failed(detail.isEmpty ? "Docker exited with code \(result.exitCode ?? -1)." : detail)
        }
    }

    private static func shortDetail(_ text: String) -> String {
        text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func looksLikeDockerUnavailable(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("docker daemon")
            || lower.contains("docker api")
            || lower.contains("is the docker daemon running")
            || lower.contains("error during connect")
            || lower.contains("cannot connect")
    }
}
