import Foundation

enum ClaudeCodeRuntime {
    static func authReadablePaths(userHome: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let trimmedHome = userHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else { return [] }
        // Claude Code's first-party `claude.ai` auth can consult the macOS
        // login keychain DB under Seatbelt. Grant only that DB file read-only;
        // metadata.keychain-db is intentionally not granted because it exposes
        // stored credential service/account names and is not needed for token use.
        return [
            (trimmedHome as NSString).appendingPathComponent("Library/Keychains/login.keychain-db")
        ]
    }

    static func vertexADCReadablePaths(
        isVertexEnabled: Bool,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        guard isVertexEnabled else { return [] }
        let trimmedHome = userHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else { return [] }
        let gcloudConfig = ExecutionEnvironmentCredentialProjection.defaultGCPADCHostPath(homeDirectory: trimmedHome)
        return [
            gcloudConfig,
            (gcloudConfig as NSString).appendingPathComponent(
                ExecutionEnvironmentCredentialProjection.gcpADCFileName
            )
        ]
    }
}
