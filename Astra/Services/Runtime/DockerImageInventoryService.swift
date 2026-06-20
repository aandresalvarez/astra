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

enum DockerImageInventoryError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case unsafeRemoteContext(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail
        case .unsafeRemoteContext(let detail):
            return detail
        }
    }
}

protocol DockerImageInventoryListing {
    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError>
}

struct DockerImageInventoryService: DockerImageInventoryListing {
    private let runner: any BinaryRunner
    private let environment: [String: String]

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.environment = environment
    }

    func listLoadedImages() async -> Result<[DockerImageReference], DockerImageInventoryError> {
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
            args: ["docker", "image", "ls", "--format", "{{.Repository}}\t{{.Tag}}\t{{.ID}}"],
            timeout: 5,
            environment: nil
        )
        guard result.isSuccess else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.unavailable(detail.isEmpty ? fallback : detail))
        }
        return .success(Self.parseImageList(result.stdout))
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
}
