import Foundation

struct AppBuildInfo: Equatable, Sendable {
    var displayName: String
    var version: String
    var build: String
    var channelRawValue: String
    var gitCommit: String
    var buildDate: String
    var bundlePath: String
    var executablePath: String

    static var current: AppBuildInfo {
        AppBuildInfo(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            bundlePath: Bundle.main.bundlePath,
            executablePath: Bundle.main.executablePath ?? "unknown"
        )
    }

    init(
        infoDictionary: [String: Any],
        bundlePath: String = "unknown",
        executablePath: String = "unknown"
    ) {
        self.displayName = Self.string(
            for: "CFBundleDisplayName",
            in: infoDictionary,
            fallback: Self.string(for: "CFBundleName", in: infoDictionary, fallback: AppChannel.current.displayName)
        )
        self.version = Self.string(for: "CFBundleShortVersionString", in: infoDictionary, fallback: "0.0.0")
        self.build = Self.string(for: "CFBundleVersion", in: infoDictionary, fallback: "0")
        self.channelRawValue = Self.string(for: "ASTRAChannel", in: infoDictionary, fallback: AppChannel.current.rawValue)
        self.gitCommit = Self.string(for: "ASTRAGitCommit", in: infoDictionary, fallback: "unknown")
        self.buildDate = Self.string(for: "ASTRABuildDate", in: infoDictionary, fallback: "unknown")
        self.bundlePath = Self.normalizedPath(bundlePath)
        self.executablePath = Self.normalizedPath(executablePath)
    }

    var channelDisplayName: String {
        AppChannel(rawValue: channelRawValue.lowercased())?.displayName ?? channelRawValue
    }

    var installedBuildSummary: String {
        "\(displayName) \(version) (\(build))"
    }

    var provenanceSummary: String {
        let commit = gitCommit == "unknown" ? "unknown" : String(gitCommit.prefix(12))
        return "\(installedBuildSummary), commit \(commit), built \(buildDate), bundle \(bundlePath)"
    }

    var auditFields: [String: String] {
        [
            "app_build": build,
            "app_version": version,
            "app_git_commit": gitCommit,
            "app_build_date": buildDate,
            "app_bundle_path": bundlePath,
            "app_executable_path": executablePath
        ]
    }

    private static func string(for key: String, in dictionary: [String: Any], fallback: String) -> String {
        guard let value = dictionary[key] as? String else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
