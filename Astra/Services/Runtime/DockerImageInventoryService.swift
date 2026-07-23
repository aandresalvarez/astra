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

    static func canonicalName(for image: String) -> String {
        guard !image.contains("@") else { return image }
        let lastPathComponent = image.split(separator: "/").last.map(String.init) ?? image
        return lastPathComponent.contains(":") ? image : "\(image):latest"
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

protocol DockerImageInventoryListing: Sendable {
    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError>
}

protocol DockerImageAvailabilityChecking: Sendable {
    func checkImageAvailability(_ image: String) async -> Result<DockerImageAvailability, DockerImageAvailabilityError>
}

enum DockerImageReadinessState: String, Equatable, Sendable {
    case ready
    case listedButUnresolvable
    case missing
    case cliMissing
    case daemonUnavailable
    case unsafeRemoteContext
    case invalidReference
}

struct DockerImageReadiness: Equatable, Sendable {
    var image: String
    var state: DockerImageReadinessState
    var imageID: String?
    var detail: String

    var isRunnable: Bool { state == .ready }
}

protocol DockerImageReadinessChecking: Sendable {
    func checkImageReadiness(_ image: String) async -> DockerImageReadiness
}

/// Defines one launch-equivalent readiness contract for both the Container
/// panel and provider preflight. `docker image ls` is discovery only: an image
/// is runnable only when Docker can resolve the exact reference via inspect.
struct DockerImageReadinessService: DockerImageReadinessChecking {
    private let inventory: any DockerImageInventoryListing
    private let availability: any DockerImageAvailabilityChecking

    init(
        inventory: any DockerImageInventoryListing = DockerImageInventoryService(),
        availability: any DockerImageAvailabilityChecking = DockerImageInventoryService()
    ) {
        self.inventory = inventory
        self.availability = availability
    }

    func checkImageReadiness(_ image: String) async -> DockerImageReadiness {
        switch await availability.checkImageAvailability(image) {
        case .success(let summary):
            return DockerImageReadiness(
                image: image,
                state: .ready,
                imageID: summary.imageID,
                detail: "Docker can resolve this image reference."
            )
        case .failure(.missingImage):
            return await diagnoseMissingReference(image)
        case .failure(.cliMissing):
            return DockerImageReadiness(
                image: image,
                state: .cliMissing,
                imageID: nil,
                detail: "Docker CLI was not found on this Mac."
            )
        case .failure(.unsafeRemoteContext(let detail)):
            return DockerImageReadiness(
                image: image,
                state: .unsafeRemoteContext,
                imageID: nil,
                detail: detail
            )
        case .failure(.invalidImageReference(let invalidImage)):
            return DockerImageReadiness(
                image: image,
                state: .invalidReference,
                imageID: nil,
                detail: "Docker image reference \(invalidImage) is invalid."
            )
        case .failure(.unavailable(let detail)):
            return DockerImageReadiness(
                image: image,
                state: .daemonUnavailable,
                imageID: nil,
                detail: detail.isEmpty ? "Docker is not available." : detail
            )
        }
    }

    private func diagnoseMissingReference(_ image: String) async -> DockerImageReadiness {
        let images: [DockerImageReference]
        switch await inventory.listLoadedImages() {
        case .success(let loadedImages):
            images = loadedImages
        case .failure(let error):
            return readiness(for: error, image: image)
        }

        let canonicalImage = DockerImageReference.canonicalName(for: image)
        guard let listed = images.first(where: {
            DockerImageReference.canonicalName(for: $0.name) == canonicalImage
        }) else {
            return DockerImageReadiness(
                image: image,
                state: .missing,
                imageID: nil,
                detail: "Docker image \(image) is not loaded on this Mac."
            )
        }

        // Prove that the immutable object still exists before offering a tag
        // repair. A stale list entry with a missing ID must remain non-runnable
        // and must never become a user-authorized `docker image tag` command.
        switch await availability.checkImageAvailability(listed.imageID) {
        case .success(let summary):
            return DockerImageReadiness(
                image: image,
                state: .listedButUnresolvable,
                imageID: summary.imageID ?? listed.imageID,
                detail: "Docker lists \(image), but cannot resolve that tag."
            )
        case .failure(let error):
            return readiness(for: error, image: image)
        }
    }

    private func readiness(for error: DockerImageInventoryError, image: String) -> DockerImageReadiness {
        switch error {
        case .cliMissing:
            return DockerImageReadiness(
                image: image,
                state: .cliMissing,
                imageID: nil,
                detail: error.localizedDescription
            )
        case .unavailable(let detail):
            return DockerImageReadiness(
                image: image,
                state: .daemonUnavailable,
                imageID: nil,
                detail: detail.isEmpty ? "Docker is not available." : detail
            )
        case .unsafeRemoteContext(let detail):
            return DockerImageReadiness(
                image: image,
                state: .unsafeRemoteContext,
                imageID: nil,
                detail: detail
            )
        }
    }

    private func readiness(for error: DockerImageAvailabilityError, image: String) -> DockerImageReadiness {
        switch error {
        case .cliMissing:
            return DockerImageReadiness(image: image, state: .cliMissing, imageID: nil, detail: error.localizedDescription)
        case .unavailable(let detail):
            return DockerImageReadiness(
                image: image,
                state: .daemonUnavailable,
                imageID: nil,
                detail: detail.isEmpty ? "Docker is not available." : detail
            )
        case .unsafeRemoteContext(let detail):
            return DockerImageReadiness(image: image, state: .unsafeRemoteContext, imageID: nil, detail: detail)
        case .missingImage:
            return DockerImageReadiness(
                image: image,
                state: .missing,
                imageID: nil,
                detail: "Docker image \(image) is not loaded on this Mac."
            )
        case .invalidImageReference(let invalidImage):
            return DockerImageReadiness(
                image: image,
                state: .invalidReference,
                imageID: nil,
                detail: "Docker image reference \(invalidImage) is invalid."
            )
        }
    }
}

struct DockerImageInventoryService: DockerImageInventoryListing, DockerImageAvailabilityChecking {
    private let runner: any BinaryRunner
    private let environmentProvider: @Sendable () -> [String: String]
    private let resolveDockerRuntime: @Sendable ([String: String]) -> DockerRuntimeResolution?

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        environment: [String: String]? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = {
            RuntimeProcessEnvironment.enriched()
        },
        resolveDockerRuntime: @escaping @Sendable ([String: String]) -> DockerRuntimeResolution? = {
            DockerRuntimeResolver.resolve(environment: $0)
        }
    ) {
        self.runner = runner
        if let environment {
            self.environmentProvider = { environment }
        } else {
            self.environmentProvider = environmentProvider
        }
        self.resolveDockerRuntime = resolveDockerRuntime
    }

    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
        let environment = environmentProvider()
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

        let environment = environmentProvider()
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
