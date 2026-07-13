import Foundation

public enum AppChannel: String {
    case production = "prod"
    case development = "dev"
    case beta = "beta"

    public static var current: AppChannel {
        resolve(
            bundleChannelRawValue: Bundle.main.object(forInfoDictionaryKey: "ASTRAChannel") as? String,
            environment: ProcessInfo.processInfo.environment,
            isPackagedApplication: Bundle.main.bundleURL.pathExtension == "app"
        )
    }

    /// Packaged identity owns channel-scoped storage. The environment remains
    /// available to unbundled SwiftPM tools, but it cannot redirect a packaged
    /// development executable into production data (or vice versa).
    public static func resolve(
        bundleChannelRawValue: String?,
        environment: [String: String],
        isPackagedApplication: Bool = false
    ) -> AppChannel {
        if let bundleChannelRawValue,
           let channel = AppChannel(rawValue: bundleChannelRawValue.lowercased()) {
            return channel
        }
        if !isPackagedApplication,
           let environmentChannel = environment["ASTRA_CHANNEL"],
           let channel = AppChannel(rawValue: environmentChannel.lowercased()) {
            return channel
        }
        return .production
    }

    public var displayName: String {
        switch self {
        case .production: "ASTRA"
        case .development: "ASTRA Dev"
        case .beta: "ASTRA Beta"
        }
    }

    public var appSupportDirectoryName: String {
        switch self {
        case .production: "Astra"
        case .development: "AstraDev"
        case .beta: "AstraBeta"
        }
    }

    public var logsDirectoryName: String {
        appSupportDirectoryName
    }

    /// The per-channel folder under `~/Documents` that holds this channel's
    /// user-facing data (Workspaces, Worktrees, …). Keeping a single source of
    /// truth keeps every channel-scoped directory consistent.
    public var documentsFolderName: String {
        switch self {
        case .production: "Astra"
        case .development: "Astra Dev"
        case .beta: "Astra Beta"
        }
    }

    public var defaultWorkspacesRoot: String {
        defaultWorkspacesRoot(fileManager: .default)
    }

    public func defaultWorkspacesRoot(fileManager: FileManager) -> String {
        channelDocumentsDirectory(fileManager: fileManager)
            .appendingPathComponent("Workspaces", isDirectory: true)
            .path
    }

    /// Root directory that holds app-managed git worktrees, kept beside the
    /// channel's Workspaces folder so worktrees are predictable, never nested
    /// inside a repository, and easy for ASTRA to enumerate and clean up.
    public var defaultWorktreesRoot: String {
        defaultWorktreesRoot(fileManager: .default)
    }

    public func defaultWorktreesRoot(fileManager: FileManager) -> String {
        channelDocumentsDirectory(fileManager: fileManager)
            .appendingPathComponent("Worktrees", isDirectory: true)
            .path
    }

    private func channelDocumentsDirectory(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(documentsFolderName, isDirectory: true)
    }

    public var keychainConnectorPrefix: String {
        switch self {
        case .production: "astra"
        case .development: "astra-dev"
        case .beta: "astra-beta"
        }
    }

    public var keychainSkillPrefix: String {
        switch self {
        case .production: "astra-skill"
        case .development: "astra-dev-skill"
        case .beta: "astra-beta-skill"
        }
    }

    /// Absolute path of ASTRA's dedicated secret keychain file — a *separate*
    /// keychain from the user's `login.keychain-db`. ASTRA's own connector/skill
    /// secrets live here so they are never inside the encrypted login-keychain
    /// blob the sandboxed agent is granted read access to (which only needs the
    /// gh/Copilot GitHub token). Conventionally placed in `~/Library/Keychains`
    /// (visible/manageable in Keychain Access) but never granted to the agent's
    /// Seatbelt read scope. See `AstraSecureKeychain` and `AstraSecureKeychainStore`.
    public var astraKeychainPath: String {
        astraKeychainPath(fileManager: .default)
    }

    public func astraKeychainPath(fileManager: FileManager) -> String {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Keychains", isDirectory: true)
            .appendingPathComponent("\(keychainConnectorPrefix).keychain-db", isDirectory: false)
            .path
    }

    /// Service name under which the dedicated keychain's random unlock password
    /// is stored as a single item in the login keychain. This is the only ASTRA
    /// item that remains in `login.keychain-db`; on its own it is useless to the
    /// agent, which cannot read the dedicated keychain file it unlocks.
    public var astraKeychainBootstrapService: String {
        "\(keychainConnectorPrefix)-keychain-bootstrap"
    }

    public var loggingSubsystem: String {
        switch self {
        case .production: "com.astra.mac"
        case .development: "com.astra.mac.dev"
        case .beta: "com.astra.mac.beta"
        }
    }

    public var isProduction: Bool {
        self == .production
    }
}
