import Foundation

enum RuntimePathResolver {
    static let usrBin = "/usr/bin"
    static let homebrewBin = "/opt/homebrew/bin"
    static let usrLocalBin = "/usr/local/bin"
    static let astraToolsPath = "\(NSHomeDirectory())/.astra/tools"

    static var shellPathSuffix: String {
        "\(usrLocalBin):\(homebrewBin)"
    }

    static var agentPathSuffix: String {
        "\(shellPathSuffix):\(astraToolsPath)"
    }

    static func detectExecutablePath(
        named executableName: String,
        candidates: [String] = [],
        fallback: String = "",
        fileManager: FileManager = .default
    ) -> String {
        let searchCandidates = candidates.isEmpty
            ? defaultExecutableCandidates(named: executableName)
            : candidates
        for path in searchCandidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executableName).path }

        for path in pathCandidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        return fallback
    }

    static func detectClaudePath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "claude",
            candidates: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(usrLocalBin)/claude",
                "\(homebrewBin)/claude",
                "\(NSHomeDirectory())/.npm-global/bin/claude"
            ],
            fallback: "\(usrLocalBin)/claude",
            fileManager: fileManager
        )
    }

    static func detectCopilotPath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "copilot",
            candidates: [
                "\(NSHomeDirectory())/.local/bin/copilot",
                "\(homebrewBin)/copilot",
                "\(usrLocalBin)/copilot",
                "\(NSHomeDirectory())/.npm-global/bin/copilot"
            ],
            fallback: "",
            fileManager: fileManager
        )
    }

    private static func defaultExecutableCandidates(named executableName: String) -> [String] {
        [
            "\(NSHomeDirectory())/.local/bin/\(executableName)",
            "\(homebrewBin)/\(executableName)",
            "\(usrLocalBin)/\(executableName)",
            "\(NSHomeDirectory())/.npm-global/bin/\(executableName)",
            "\(astraToolsPath)/\(executableName)",
            "\(usrBin)/\(executableName)"
        ]
    }
}
