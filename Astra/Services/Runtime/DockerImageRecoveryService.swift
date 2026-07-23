import Foundation
import ASTRACore

struct DockerImageRecoveryEventPayload: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable {
        case started
        case succeeded
        case failed
    }

    var image: String
    var action: String
    var result: Result
    var imageID: String?
    var detail: String?
}

struct DockerImageRecoveryWorkspace: Equatable, Sendable {
    var primaryPath: String
    var additionalPaths: [String]
    /// The source root persisted by the failed run. A rebuild must use this
    /// root when multiple workspace Dockerfiles generate the same image tag.
    var preferredSourcePath: String? = nil
}

enum DockerImageRecoveryAction: Equatable, Sendable {
    case retryOnly
    case retag(imageID: String)
    case rebuild(DockerImageBuildRequest)
}

struct DockerImageRecoveryPlan: Equatable, Sendable {
    var image: String
    var action: DockerImageRecoveryAction
    var title: String
    var confirmation: String
    var auditAction: String
}

enum DockerImageRecoveryError: LocalizedError, Equatable, Sendable {
    case notRecoverable(String)
    case invalidImageID(String)
    case tagFailed(String)
    case buildFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRecoverable(let detail),
             .invalidImageID(let detail),
             .tagFailed(let detail),
             .buildFailed(let detail),
             .verificationFailed(let detail):
            return detail
        }
    }
}

protocol DockerImageTagging: Sendable {
    func tagImage(imageID: String, as image: String) async -> Result<Void, DockerImageRecoveryError>
}

struct DockerImageTagService: DockerImageTagging {
    private let runner: any BinaryRunner
    private let environmentProvider: @Sendable () -> [String: String]
    private let resolveDockerRuntime: @Sendable ([String: String]) -> DockerRuntimeResolution?

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        environmentProvider: @escaping @Sendable () -> [String: String] = {
            RuntimeProcessEnvironment.enriched()
        },
        resolveDockerRuntime: @escaping @Sendable ([String: String]) -> DockerRuntimeResolution? = {
            DockerRuntimeResolver.resolve(environment: $0)
        }
    ) {
        self.runner = runner
        self.environmentProvider = environmentProvider
        self.resolveDockerRuntime = resolveDockerRuntime
    }

    func tagImage(imageID: String, as image: String) async -> Result<Void, DockerImageRecoveryError> {
        guard Self.isSafeImageID(imageID),
              DockerExecutionPlanner.isSafeDockerImageReference(image) else {
            return .failure(.invalidImageID("ASTRA refused to construct an unsafe Docker tag repair."))
        }

        let environment = environmentProvider()
        guard let dockerRuntime = resolveDockerRuntime(environment) else {
            return .failure(.tagFailed("Docker CLI was not found on this Mac."))
        }

        let contextResult = await runner.run(
            path: dockerRuntime.executablePath,
            args: ["context", "show"],
            timeout: 3,
            environment: dockerRuntime.environment
        )
        guard contextResult.isSuccess else {
            return .failure(.tagFailed(Self.failureDetail(contextResult)))
        }
        let context = contextResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let readiness = DockerReadinessService.evaluate(
            dockerStatus: .healthy(path: "docker", version: ""),
            dockerContext: context,
            dockerHost: dockerRuntime.environment["DOCKER_HOST"]
        )
        guard readiness.state != .unsafeRemoteContext else {
            return .failure(.tagFailed(readiness.issue ?? "Docker is using an unapproved remote context."))
        }

        let result = await runner.run(
            path: dockerRuntime.executablePath,
            args: ["image", "tag", imageID, image],
            timeout: 10,
            environment: dockerRuntime.environment
        )
        guard result.isSuccess else {
            return .failure(.tagFailed(Self.failureDetail(result)))
        }
        return .success(())
    }

    private static func isSafeImageID(_ value: String) -> Bool {
        let hex = value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
        return (12...64).contains(hex.count) && hex.allSatisfy { $0.isHexDigit }
    }

    private static func failureDetail(_ result: RunResult) -> String {
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        let detail = raw.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return detail ?? result.launchError ?? "Docker exited with code \(result.exitCode ?? -1)."
    }
}

protocol DockerImageRecovering: Sendable {
    func recoveryPlan(
        image: String,
        workspace: DockerImageRecoveryWorkspace
    ) async -> Result<DockerImageRecoveryPlan, DockerImageRecoveryError>

    func performRecovery(_ plan: DockerImageRecoveryPlan) async -> Result<Void, DockerImageRecoveryError>
}

/// Plans only repairs that can be proven from local state, performs exactly one
/// user-authorized mutation, and verifies the same exact-reference readiness
/// contract before the caller is allowed to retry a task.
struct DockerImageRecoveryService: DockerImageRecovering {
    private let readiness: any DockerImageReadinessChecking
    private let tagger: any DockerImageTagging
    private let builder: any DockerImageBuilding

    init(
        readiness: any DockerImageReadinessChecking = DockerImageReadinessService(),
        tagger: any DockerImageTagging = DockerImageTagService(),
        builder: any DockerImageBuilding = DockerImageBuildService()
    ) {
        self.readiness = readiness
        self.tagger = tagger
        self.builder = builder
    }

    func recoveryPlan(
        image: String,
        workspace: DockerImageRecoveryWorkspace
    ) async -> Result<DockerImageRecoveryPlan, DockerImageRecoveryError> {
        let report = await readiness.checkImageReadiness(image)
        switch report.state {
        case .ready:
            return .success(DockerImageRecoveryPlan(
                image: image,
                action: .retryOnly,
                title: "Image is ready",
                confirmation: "Docker can now resolve \(image). Retry the task.",
                auditAction: "retry_only"
            ))
        case .listedButUnresolvable:
            guard let imageID = report.imageID else {
                return .failure(.notRecoverable("Docker did not provide an immutable image ID for a safe tag repair."))
            }
            return .success(DockerImageRecoveryPlan(
                image: image,
                action: .retag(imageID: imageID),
                title: "Repair image tag and retry?",
                confirmation: "ASTRA will restore \(image) from verified image ID \(imageID), verify the tag, and then retry the task.",
                auditAction: "retag"
            ))
        case .missing:
            let request: DockerImageBuildRequest
            switch Self.buildRequest(image: image, workspace: workspace) {
            case .success(let value):
                request = value
            case .failure(let error):
                return .failure(error)
            }
            return .success(DockerImageRecoveryPlan(
                image: image,
                action: .rebuild(request),
                title: "Rebuild image and retry?",
                confirmation: "ASTRA will execute the workspace Dockerfile to rebuild \(image), verify the image, and then retry the task.",
                auditAction: "rebuild"
            ))
        case .cliMissing, .daemonUnavailable, .unsafeRemoteContext, .invalidReference:
            return .failure(.notRecoverable(report.detail))
        }
    }

    func performRecovery(_ plan: DockerImageRecoveryPlan) async -> Result<Void, DockerImageRecoveryError> {
        switch plan.action {
        case .retryOnly:
            break
        case .retag(let imageID):
            if case .failure(let error) = await tagger.tagImage(imageID: imageID, as: plan.image) {
                return .failure(error)
            }
        case .rebuild(let request):
            if case .failure(let error) = await builder.buildImage(request) {
                return .failure(.buildFailed(error.localizedDescription))
            }
        }

        let verified = await readiness.checkImageReadiness(plan.image)
        guard verified.isRunnable else {
            return .failure(.verificationFailed(
                "Docker repair finished, but \(plan.image) still failed launch verification: \(verified.detail)"
            ))
        }
        return .success(())
    }

    private static func buildRequest(
        image: String,
        workspace: DockerImageRecoveryWorkspace
    ) -> Result<DockerImageBuildRequest, DockerImageRecoveryError> {
        let matches = DockerWorkspaceDiscoveryService.candidates(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        .filter { candidate in
            guard candidate.environment.kind == .dockerfile,
                  let candidateImage = candidate.environment.image else { return false }
            return imageWithDefaultTag(candidateImage) == image
        }

        let selected: DockerWorkspaceCandidate
        if let preferredSourcePath = workspace.preferredSourcePath {
            let preferred = WorkspacePathPresentation.standardizedPath(preferredSourcePath)
            let sourceMatches = matches.filter {
                $0.environment.sourcePath.map(WorkspacePathPresentation.standardizedPath) == preferred
            }
            guard sourceMatches.count == 1, let match = sourceMatches.first else {
                return .failure(.notRecoverable(
                    "ASTRA refused to rebuild \(image) because the failed run's source path does not identify exactly one matching workspace Dockerfile."
                ))
            }
            selected = match
        } else {
            guard matches.count == 1, let match = matches.first else {
                let detail = matches.count > 1
                    ? "ASTRA found multiple workspace Dockerfiles that build \(image) and refused to choose the wrong project. Select the intended container environment and retry."
                    : "The image is missing and ASTRA could not find a matching workspace Dockerfile. Build or pull the image in the Container panel, or choose another environment."
                return .failure(.notRecoverable(detail))
            }
            selected = match
        }

        guard let dockerfilePath = selected.environment.dockerfilePath,
              let sourcePath = selected.environment.sourcePath else {
            return .failure(.notRecoverable("The matching Docker environment is missing its Dockerfile or source path."))
        }
        return .success(DockerImageBuildRequest(
            image: image,
            dockerfilePath: dockerfilePath,
            sourcePath: sourcePath
        ))
    }

    private static func imageWithDefaultTag(_ image: String) -> String {
        guard !image.contains("@") else { return image }
        let lastPathComponent = image.split(separator: "/").last.map(String.init) ?? image
        return lastPathComponent.contains(":") ? image : "\(image):latest"
    }
}
