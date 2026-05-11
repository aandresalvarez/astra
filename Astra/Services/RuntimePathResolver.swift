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

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [executableName]
        let pipe = Pipe()
        which.standardOutput = pipe
        do {
            try which.run()
            which.waitUntilExit()
        } catch {
            return fallback
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? fallback : path
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
