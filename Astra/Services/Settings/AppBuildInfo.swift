import Foundation

struct AppBuildInfo: Equatable, Sendable {
    var displayName: String
    var version: String
    var build: String
    var channelRawValue: String

    static var current: AppBuildInfo {
        AppBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        self.displayName = Self.string(
            for: "CFBundleDisplayName",
            in: infoDictionary,
            fallback: Self.string(for: "CFBundleName", in: infoDictionary, fallback: AppChannel.current.displayName)
        )
        self.version = Self.string(for: "CFBundleShortVersionString", in: infoDictionary, fallback: "0.0.0")
        self.build = Self.string(for: "CFBundleVersion", in: infoDictionary, fallback: "0")
        self.channelRawValue = Self.string(for: "ASTRAChannel", in: infoDictionary, fallback: AppChannel.current.rawValue)
    }

    var channelDisplayName: String {
        AppChannel(rawValue: channelRawValue.lowercased())?.displayName ?? channelRawValue
    }

    var installedBuildSummary: String {
        "\(displayName) \(version) (\(build))"
    }

    private static func string(for key: String, in dictionary: [String: Any], fallback: String) -> String {
        guard let value = dictionary[key] as? String else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
