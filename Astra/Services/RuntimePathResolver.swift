import Foundation

enum RuntimePathResolver {
    static let homebrewBin = "/opt/homebrew/bin"
    static let usrLocalBin = "/usr/local/bin"
    static let astraToolsPath = "\(NSHomeDirectory())/.astra/tools"

    static var shellPathSuffix: String {
        "\(usrLocalBin):\(homebrewBin)"
    }

    static var agentPathSuffix: String {
        "\(shellPathSuffix):\(astraToolsPath)"
    }

    static func detectClaudePath(fileManager: FileManager = .default) -> String {
        detectExecutable(
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
        detectExecutable(
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

    private static func detectExecutable(
        named executableName: String,
        candidates: [String],
        fallback: String,
        fileManager: FileManager
    ) -> String {
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
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
}
