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
            "disable", "enable", "modify", "put", "remove", "remove-iam-policy-binding",
            "restart", "rm", "set", "set-iam-policy", "start", "stop", "update", "write"
        ],
        readVerbs: [
            "describe", "get", "get-iam-policy", "info", "list", "ls", "read", "show", "status", "version", "view"
        ],
        optionsWithValues: [
            "--account", "--billing-project", "--configuration", "--format", "--project",
            "--project-id", "--region", "--sort-by", "--uri", "--zone"
        ]
    )

    private let toolName: String
    private let deniedFamilies: Set<String>
    private let deniedVerbs: Set<String>
    private let readVerbs: Set<String>
    private let optionsWithValues: Set<String>

    init(
        toolName: String,
        deniedFamilies: Set<String>,
        deniedVerbs: Set<String>,
        readVerbs: Set<String>,
        optionsWithValues: Set<String>
    ) {
        self.toolName = toolName
        self.deniedFamilies = deniedFamilies
        self.deniedVerbs = deniedVerbs
        self.readVerbs = readVerbs
        self.optionsWithValues = optionsWithValues
    }

    func evaluate(arguments rawArguments: [String]) -> Decision {
        let arguments = rawArguments.map(Self.comparableToken)
        guard !arguments.isEmpty else {
            return .denied("\(toolName) requires an operation")
        }
        if arguments.contains(where: Self.containsCredentialDisclosureMarker) {
            return .denied(deniedOperationMessage)
        }

        let actionTokens = dropLeadingOptions(arguments)
        guard !actionTokens.isEmpty else {
            return .denied("\(toolName) requires an operation")
        }
        if actionTokens.contains(where: deniedFamilies.contains) ||
            actionTokens.contains(where: deniedVerbs.contains) {
            return .denied(deniedOperationMessage)
        }
        if actionTokens.contains(where: readVerbs.contains) {
            return .allowed
        }
        return .denied("\(toolName) only allows read-only operations through host control")
    }

    private var deniedOperationMessage: String {
        "\(toolName) does not allow credential or mutating operations through host control"
    }

    private func dropLeadingOptions(_ arguments: [String]) -> [String] {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-") else { break }
            index += 1
            let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if optionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                index += 1
            }
        }
        return Array(arguments.dropFirst(index))
    }

    private static func comparableToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsCredentialDisclosureMarker(_ token: String) -> Bool {
        token.contains("access-token") ||
            token.contains("credential") ||
            token.contains("password") ||
            token.contains("secret") ||
            token.contains("token") ||
            token == "--impersonate-service-account" ||
            token.hasPrefix("--impersonate-service-account=")
    }
}
