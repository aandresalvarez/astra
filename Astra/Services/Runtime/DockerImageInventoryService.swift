import Foundation
import ASTRACore

struct DockerImageReference: Identifiable, Equatable, Sendable {
    var repository: String
    var tag: String
    var imageID: String

    var id: String { name }

    var name: String {
        tag.isEmpty || tag == "<none>" ? repository : "\(repository):\(tag)"
    }
}

struct DockerImageAvailability: Equatable, Sendable {
    var image: String
    var imageID: String?
}

enum DockerImageInventoryError: LocalizedError, Equatable, Sendable {
    case cliMissing
    case unavailable(String)
    case unsafeRemoteContext(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "Docker CLI was not found. Install or reopen Docker Desktop, then refresh."
        case .unavailable(let detail):
            return detail
        case .unsafeRemoteContext(let detail):
            return detail
        }
    }
}

enum DockerImageAvailabilityError: LocalizedError, Equatable, Sendable {
    case cliMissing
    case unavailable(String)
    case unsafeRemoteContext(String)
    case missingImage(String)
    case invalidImageReference(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "Docker CLI was not found. Install or reopen Docker Desktop, then retry."
        case .unavailable(let detail):
            return detail.isEmpty ? "Docker is not available." : detail
        case .unsafeRemoteContext(let detail):
            return detail
        case .missingImage(let image):
            return "Docker image \(image) is not loaded."
        case .invalidImageReference(let image):
            return "Docker image reference \(image) is not safe to run."
        }
    }
}

protocol DockerImageInventoryListing {
    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError>
}

protocol DockerImageAvailabilityChecking {
    func checkImageAvailability(_ image: String) async -> Result<DockerImageAvailability, DockerImageAvailabilityError>
}

struct DockerImageInventoryService: DockerImageInventoryListing, DockerImageAvailabilityChecking {
    private let runner: any BinaryRunner
    private let environment: [String: String]
    private let resolveDockerRuntime: @Sendable ([String: String]) -> DockerRuntimeResolution?

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        environment: [String: String] = RuntimeProcessEnvironment.enriched(),
        resolveDockerRuntime: @escaping @Sendable ([String: String]) -> DockerRuntimeResolution? = {
            DockerRuntimeResolver.resolve(environment: $0)
        }
    ) {
        self.runner = runner
        self.environment = environment
        self.resolveDockerRuntime = resolveDockerRuntime
    }

    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
        guard let dockerRuntime = resolveDockerRuntime(environment) else {
            return .failure(.cliMissing)
        }

        let contextResult = await runner.run(
            path: dockerRuntime.executablePath,
            args: ["context", "show"],
            timeout: 3,
            environment: dockerRuntime.environment
        )
        guard contextResult.isSuccess else {
            return .failure(.unavailable(Self.failureDetail(contextResult)))
        }
        let context = contextResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let readiness = DockerReadinessService.evaluate(
            dockerStatus: .healthy(path: "docker", version: ""),
            dockerContext: context,
            dockerHost: dockerRuntime.environment["DOCKER_HOST"]
        )
        guard readiness.state != .unsafeRemoteContext else {
            return .failure(.unsafeRemoteContext(readiness.issue ?? "Docker is using a remote context."))
        }

        let result = await runner.run(
            path: dockerRuntime.executablePath,
            args: ["image", "ls", "--format", "{{.Repository}}\t{{.Tag}}\t{{.ID}}"],
            timeout: 5,
            environment: dockerRuntime.environment
        )
        guard result.isSuccess else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.unavailable(detail.isEmpty ? fallback : detail))
        }
        return .success(Self.parseImageList(result.stdout))
    }

    func checkImageAvailability(_ image: String) async -> Result<DockerImageAvailability, DockerImageAvailabilityError> {
        let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == image,
              DockerExecutionPlanner.isSafeDockerImageReference(trimmed) else {
            return .failure(.invalidImageReference(image))
        }

        guard let dockerRuntime = resolveDockerRuntime(environment) else {
            return .failure(.cliMissing)
        }

        switch await localDockerContext(dockerRuntime: dockerRuntime) {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }

        let result = await runner.run(
            path: dockerRuntime.executablePath,
            args: ["image", "inspect", "--format", "{{.Id}}", image],
            timeout: 5,
            environment: dockerRuntime.environment
        )
        guard result.isSuccess else {
            return .failure(Self.availabilityError(for: image, result: result))
        }

        let imageID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(DockerImageAvailability(
            image: image,
            imageID: imageID.isEmpty ? nil : imageID
        ))
    }

    static func parseImageList(_ output: String) -> [DockerImageReference] {
        var seen: Set<String> = []
        return output
            .split(separator: "\n")
            .compactMap { line -> DockerImageReference? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3 else { return nil }
                let repository = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let tag = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let imageID = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repository.isEmpty, repository != "<none>" else { return nil }
                let ref = DockerImageReference(repository: repository, tag: tag, imageID: imageID)
                guard !seen.contains(ref.name) else { return nil }
                seen.insert(ref.name)
                return ref
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func localDockerContext(dockerRuntime: DockerRuntimeResolution) async -> Result<Void, DockerImageAvailabilityError> {
        let contextResult = await runner.run(
            path: dockerRuntime.executablePath,
            args: ["context", "show"],
            timeout: 3,
            environment: dockerRuntime.environment
        )
        guard contextResult.isSuccess else {
            return .failure(.unavailable(Self.failureDetail(contextResult)))
        }
        let context = contextResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let readiness = DockerReadinessService.evaluate(
            dockerStatus: .healthy(path: "docker", version: ""),
            dockerContext: context,
            dockerHost: dockerRuntime.environment["DOCKER_HOST"]
        )
        guard readiness.state != .unsafeRemoteContext else {
            return .failure(.unsafeRemoteContext(readiness.issue ?? "Docker is using a remote context."))
        }
        return .success(())
    }

    private static func availabilityError(
        for image: String,
        result: RunResult
    ) -> DockerImageAvailabilityError {
        switch result.outcome {
        case .timedOut:
            return .unavailable("Docker image inspect timed out.")
        case .cancelled:
            return .unavailable("Docker image inspect was cancelled.")
        case .launchFailed:
            return .unavailable(shortDetail(result.launchError ?? "Docker could not launch."))
        case .exited:
            let detail = shortDetail(result.stderr.isEmpty ? result.stdout : result.stderr)
            let lower = detail.lowercased()
            if lower.contains("no such image")
                || lower.contains("no such object")
                || lower.contains("not found") {
                return .missingImage(image)
            }
            if looksLikeDockerUnavailable(lower) {
                return .unavailable(detail)
            }
            return .unavailable(detail.isEmpty ? "Docker exited with code \(result.exitCode ?? -1)." : detail)
        }
    }

    private static func shortDetail(_ text: String) -> String {
        text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func failureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .timedOut:
            return "Docker context check timed out."
        case .cancelled:
            return "Docker context check was cancelled."
        case .launchFailed:
            return shortDetail(result.launchError ?? "Docker could not launch.")
        case .exited:
            let detail = shortDetail(result.stderr.isEmpty ? result.stdout : result.stderr)
            return detail.isEmpty ? "Docker exited with code \(result.exitCode ?? -1)." : detail
        }
    }

    private static func looksLikeDockerUnavailable(_ lower: String) -> Bool {
        lower.contains("docker daemon")
            || lower.contains("docker api")
            || lower.contains("is the docker daemon running")
            || lower.contains("error during connect")
            || lower.contains("cannot connect")
    }
}
