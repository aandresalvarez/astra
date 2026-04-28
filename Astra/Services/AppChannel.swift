import Foundation

enum AppChannel: String {
    case production = "prod"
    case development = "dev"
    case beta = "beta"

    static var current: AppChannel {
        if let env = ProcessInfo.processInfo.environment["ASTRA_CHANNEL"],
           let channel = AppChannel(rawValue: env.lowercased()) {
            return channel
        }
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "ASTRAChannel") as? String,
           let channel = AppChannel(rawValue: plistValue.lowercased()) {
            return channel
        }
        return .production
    }

    var displayName: String {
        switch self {
        case .production: "ASTRA"
        case .development: "ASTRA Dev"
        case .beta: "ASTRA Beta"
        }
    }

    var appSupportDirectoryName: String {
        switch self {
        case .production: "Astra"
        case .development: "AstraDev"
        case .beta: "AstraBeta"
        }
    }

    var logsDirectoryName: String {
        appSupportDirectoryName
    }

    var defaultWorkspacesRoot: String {
        let documents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        switch self {
        case .production:
            return documents
                .appendingPathComponent("Astra", isDirectory: true)
                .appendingPathComponent("Workspaces", isDirectory: true)
                .path
        case .development:
            return documents
                .appendingPathComponent("Astra Dev", isDirectory: true)
                .appendingPathComponent("Workspaces", isDirectory: true)
                .path
        case .beta:
            return documents
                .appendingPathComponent("Astra Beta", isDirectory: true)
                .appendingPathComponent("Workspaces", isDirectory: true)
                .path
        }
    }

    var keychainConnectorPrefix: String {
        switch self {
        case .production: "astra"
        case .development: "astra-dev"
        case .beta: "astra-beta"
        }
    }

    var keychainSkillPrefix: String {
        switch self {
        case .production: "astra-skill"
        case .development: "astra-dev-skill"
        case .beta: "astra-beta-skill"
        }
    }

    var loggingSubsystem: String {
        switch self {
        case .production: "com.astra.mac"
        case .development: "com.astra.mac.dev"
        case .beta: "com.astra.mac.beta"
        }
    }

    var isProduction: Bool {
        self == .production
    }
}
