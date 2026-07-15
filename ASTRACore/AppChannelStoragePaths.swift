import Foundation

/// Owns channel-scoped ASTRA storage paths without changing the process home.
///
/// Development builds sometimes need a disposable store to validate an older
/// schema or an in-progress branch. Redirecting `HOME`/`CFFIXED_USER_HOME` is
/// too broad because provider CLIs also use the user home for authentication.
/// `ASTRA_DEV_APP_SUPPORT_DIR` therefore redirects only ASTRA's development
/// Application Support directory. Production and beta builds always ignore it.
public enum AppChannelStoragePaths {
    public static let developmentApplicationSupportOverrideEnvironmentKey =
        "ASTRA_DEV_APP_SUPPORT_DIR"

    public static func applicationSupportDirectory(
        for channel: AppChannel = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = developmentApplicationSupportOverride(
            for: channel,
            environment: environment
        ) {
            return override
        }
        return applicationSupportBaseDirectory(
            for: channel,
            environment: environment,
            fileManager: fileManager
        )
        .appendingPathComponent(channel.appSupportDirectoryName, isDirectory: true)
    }

    public static func applicationSupportBaseDirectory(
        for channel: AppChannel = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = developmentApplicationSupportOverride(
            for: channel,
            environment: environment
        ) {
            return override.deletingLastPathComponent()
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Accept only an absolute, channel-specific directory. Requiring the
    /// `AstraDev` suffix prevents a typo from redirecting ASTRA to a broad root
    /// such as `/tmp` or the user's home directory.
    public static func developmentApplicationSupportOverride(
        for channel: AppChannel,
        environment: [String: String]
    ) -> URL? {
        guard channel == .development,
              let rawValue = environment[developmentApplicationSupportOverrideEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              NSString(string: rawValue).isAbsolutePath else {
            return nil
        }
        let url = URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL
        guard url.lastPathComponent == channel.appSupportDirectoryName else {
            return nil
        }
        return url
    }
}
