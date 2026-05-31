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

    /// The per-channel folder under `~/Documents` that holds this channel's
    /// user-facing data (Workspaces, Worktrees, …). Keeping a single source of
    /// truth keeps every channel-scoped directory consistent.
    var documentsFolderName: String {
        switch self {
        case .production: "Astra"
        case .development: "Astra Dev"
        case .beta: "Astra Beta"
        }
    }

    var defaultWorkspacesRoot: String {
        defaultWorkspacesRoot(fileManager: .default)
    }

    func defaultWorkspacesRoot(fileManager: FileManager) -> String {
        channelDocumentsDirectory(fileManager: fileManager)
            .appendingPathComponent("Workspaces", isDirectory: true)
            .path
    }

    /// Root directory that holds app-managed git worktrees, kept beside the
    /// channel's Workspaces folder so worktrees are predictable, never nested
    /// inside a repository, and easy for ASTRA to enumerate and clean up.
    var defaultWorktreesRoot: String {
        defaultWorktreesRoot(fileManager: .default)
    }

    func defaultWorktreesRoot(fileManager: FileManager) -> String {
        channelDocumentsDirectory(fileManager: fileManager)
            .appendingPathComponent("Worktrees", isDirectory: true)
            .path
    }

    private func channelDocumentsDirectory(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(documentsFolderName, isDirectory: true)
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
