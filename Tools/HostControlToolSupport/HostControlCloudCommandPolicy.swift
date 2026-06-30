import Foundation

struct HostControlCloudCommandPolicy: Sendable {
    enum Decision: Equatable {
        case allowed
        case denied(String)
    }

    static let gcloud = HostControlCloudCommandPolicy(
        toolName: "gcloud",
        deniedFamilies: [
            "auth", "config", "iam", "kms", "secrets", "secret-manager"
        ],
        deniedVerbs: [
            "add-iam-policy-binding", "attach", "call", "create", "delete", "deploy", "detach",
            "disable", "enable", "execute", "get-iam-policy", "modify", "put", "remove", "remove-iam-policy-binding",
            "reset", "restart", "rm", "set", "set-iam-policy", "start", "stop", "update", "write"
        ],
        readVerbs: [
            "describe", "get", "info", "list", "ls", "read", "show", "status", "version", "view"
        ],
        optionsWithValues: [
            "--account", "--billing-project", "--configuration", "--filter", "--flatten",
            "--format", "--limit", "--page-size", "--project", "--project-id", "--region",
            "--sort-by", "--trace-token", "--uri", "--verbosity", "--zone"
        ],
        readCommandGroups: [
            "access-approval", "active-directory", "ai", "alloydb", "artifacts", "asset",
            "billing", "builds", "compute", "container", "dataflow", "dataproc", "dns",
            "functions", "logging", "monitoring", "projects", "pubsub", "redis", "run",
            "scheduler", "services", "source", "sql", "storage", "workflows",
            "addresses", "clusters", "disks", "firewalls", "forwarding-rules", "images",
            "instance-groups", "instances", "jobs", "logs", "networks", "node-pools",
            "operations", "repositories", "routes", "snapshots", "subnetworks", "topics",
            "zones", "regions"
        ]
    )

    private let toolName: String
    private let deniedFamilies: Set<String>
    private let deniedVerbs: Set<String>
    private let readVerbs: Set<String>
    private let optionsWithValues: Set<String>
    private let readCommandGroups: Set<String>
    private let deniedCommandPrefixes: Set<[String]> = [
        ["workflows", "run"]
    ]

    init(
        toolName: String,
        deniedFamilies: Set<String>,
        deniedVerbs: Set<String>,
        readVerbs: Set<String>,
        optionsWithValues: Set<String>,
        readCommandGroups: Set<String>
    ) {
        self.toolName = toolName
        self.deniedFamilies = deniedFamilies
        self.deniedVerbs = deniedVerbs
        self.readVerbs = readVerbs
        self.optionsWithValues = optionsWithValues
        self.readCommandGroups = readCommandGroups
    }

    func evaluate(arguments rawArguments: [String]) -> Decision {
        let arguments = rawArguments.map(Self.comparableToken)
        guard !arguments.isEmpty else {
            return .denied("\(toolName) requires an operation")
        }
        if containsDeniedFlag(in: arguments) {
            return .denied(deniedOperationMessage)
        }

        let actionTokens = commandTokens(from: arguments)
        guard !actionTokens.isEmpty else {
            return .denied("\(toolName) requires an operation")
        }
        if containsDeniedCommandPrefix(in: actionTokens) {
            return .denied(deniedOperationMessage)
        }

        let operationIndex = operationTokenIndex(in: actionTokens)
        let commandPath = operationIndex.map { Array(actionTokens.prefix(through: $0)) } ?? actionTokens
        if commandPath.contains(where: Self.containsCredentialDisclosureMarker) {
            return .denied(deniedOperationMessage)
        }

        guard let operationIndex else {
            if actionTokens.contains(where: deniedFamilies.contains) ||
                actionTokens.contains(where: deniedVerbs.contains) {
                return .denied(deniedOperationMessage)
            }
            return .denied("\(toolName) only allows read-only operations through host control")
        }
        let operation = actionTokens[operationIndex]
        if deniedFamilies.contains(operation) || deniedVerbs.contains(operation) {
            return .denied(deniedOperationMessage)
        }
        if readVerbs.contains(operation) {
            return .allowed
        }
        return .denied("\(toolName) only allows read-only operations through host control")
    }

    private var deniedOperationMessage: String {
        "\(toolName) does not allow credential or mutating operations through host control"
    }

    private func commandTokens(from arguments: [String]) -> [String] {
        var tokens: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                tokens.append(contentsOf: arguments.dropFirst(index))
                break
            }
            if token.hasPrefix("-") {
                index += 1
                let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                if optionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                    index += 1
                }
                continue
            }
            tokens.append(token)
            index += 1
        }
        return tokens
    }

    private func operationTokenIndex(in tokens: [String]) -> Int? {
        for (index, token) in tokens.enumerated() {
            if readCommandGroups.contains(token) {
                continue
            }
            return index
        }
        return nil
    }

    private func containsDeniedCommandPrefix(in tokens: [String]) -> Bool {
        deniedCommandPrefixes.contains { prefix in
            tokens.starts(with: prefix)
        }
    }

    private static func comparableToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsCredentialDisclosureMarker(_ token: String) -> Bool {
        token.contains("access-token") ||
            token.contains("identity-token") ||
            token.contains("credential") ||
            token.contains("password") ||
            token.contains("secret")
    }

    private func containsDeniedFlag(in arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                return false
            }
            guard token.hasPrefix("-") else {
                index += 1
                continue
            }

            let nextToken = index + 1 < arguments.count ? arguments[index + 1] : nil
            if Self.containsCredentialDisclosureFlag(token) ||
                Self.containsHTTPLoggingFlag(token) ||
                Self.usesDebugVerbosity(token, nextToken: nextToken) {
                return true
            }

            let optionName = Self.optionName(for: token)
            index += 1
            if optionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                index += 1
            }
        }
        return false
    }

    private static func containsCredentialDisclosureFlag(_ token: String) -> Bool {
        let flagName = optionName(for: token)
        return flagName == "--flags-file" ||
            flagName == "--impersonate-service-account" ||
            flagName.contains("access-token") ||
            flagName.contains("identity-token") ||
            flagName.contains("credential") ||
            flagName.contains("password") ||
            flagName.contains("secret")
    }

    private static func containsHTTPLoggingFlag(_ token: String) -> Bool {
        let flagName = optionName(for: token)
        return flagName == "--log-http" || flagName == "--httplib2-debuglevel"
    }

    private static func usesDebugVerbosity(_ token: String, nextToken: String?) -> Bool {
        if token == "--verbosity" {
            return nextToken == "debug"
        }
        guard token.hasPrefix("--verbosity=") else {
            return false
        }
        return token.split(separator: "=", maxSplits: 1).dropFirst().first == "debug"
    }

    private static func optionName(for token: String) -> String {
        token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
    }
}
