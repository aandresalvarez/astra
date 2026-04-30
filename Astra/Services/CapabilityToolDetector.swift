import Foundation
import ASTRACore

struct CapabilityToolDetector {
    struct Candidate: Identifiable {
        let id: String
        let name: String
        let description: String
        let command: String
        let arguments: String
        let prerequisite: CLIPrerequisite
    }

    static let knownCandidates: [Candidate] = [
        Candidate(
            id: "bq",
            name: "bq - BigQuery CLI",
            description: "Run BigQuery jobs and inspect datasets",
            command: "bq",
            arguments: "",
            prerequisite: CLIPrerequisite(
                binary: "bq",
                livenessArgs: ["version"],
                displayName: "BigQuery CLI",
                purpose: "Runs BigQuery commands for data analysis.",
                installURL: URL(string: "https://cloud.google.com/sdk/docs/install"),
                installHint: "Install with Google Cloud SDK: `brew install --cask google-cloud-sdk`",
                authHint: "Run `gcloud auth login` and `gcloud auth application-default login`."
            )
        ),
        Candidate(
            id: "gcloud",
            name: "gcloud - Google Cloud CLI",
            description: "Manage Google Cloud projects, auth, and services",
            command: "gcloud",
            arguments: "",
            prerequisite: CommonCLIPrerequisites.gcloud
        ),
        Candidate(
            id: "gh",
            name: "gh - GitHub CLI",
            description: "Work with GitHub issues, PRs, repos, and Actions",
            command: "gh",
            arguments: "",
            prerequisite: CommonCLIPrerequisites.githubCLI
        ),
        Candidate(
            id: "docker",
            name: "docker - Docker CLI",
            description: "Inspect containers, images, and local Docker state",
            command: "docker",
            arguments: "",
            prerequisite: CommonCLIPrerequisites.docker
        ),
        Candidate(
            id: "jq",
            name: "jq - JSON Processor",
            description: "Filter and transform JSON from files or command output",
            command: "jq",
            arguments: "",
            prerequisite: CLIPrerequisite(
                binary: "jq",
                displayName: "jq",
                purpose: "Filters JSON data in shell workflows.",
                installURL: URL(string: "https://jqlang.github.io/jq/"),
                installHint: "Install via Homebrew: `brew install jq`"
            )
        ),
        Candidate(
            id: "curl",
            name: "curl - HTTP Client",
            description: "Call HTTP APIs from local command workflows",
            command: "curl",
            arguments: "",
            prerequisite: CLIPrerequisite(
                binary: "curl",
                displayName: "curl",
                purpose: "Calls HTTP APIs from shell workflows.",
                installURL: URL(string: "https://curl.se/"),
                installHint: "curl is included with macOS; install via Homebrew if you need a newer version."
            )
        )
    ]

    private let checker: EnvironmentHealthChecker

    init(checker: EnvironmentHealthChecker = EnvironmentHealthChecker()) {
        self.checker = checker
    }

    func detect(_ candidates: [Candidate] = Self.knownCandidates) async -> [String: HealthStatus] {
        var statuses: [String: HealthStatus] = [:]
        for candidate in candidates {
            statuses[candidate.id] = await checker.check(
                binary: candidate.prerequisite.binary,
                livenessArgs: candidate.prerequisite.livenessArgs,
                semantic: candidate.prerequisite.semantic
            )
        }
        return statuses
    }

    static func makeTool(for candidate: Candidate) -> LocalTool {
        LocalTool(
            name: candidate.name,
            toolDescription: candidate.description,
            icon: "terminal",
            toolType: "cli",
            command: candidate.command,
            arguments: candidate.arguments
        )
    }

    static func prerequisite(forCommand command: String) -> CLIPrerequisite? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return knownCandidates.first { $0.command == normalized }?.prerequisite
    }
}
