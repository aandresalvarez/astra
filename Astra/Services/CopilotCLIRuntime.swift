import Foundation
import ASTRACore

struct CopilotCLICapabilities: Equatable {
    var supportsOutputFormatJSON: Bool
    var supportsStreamingFlag: Bool
    var supportsNoAskUser: Bool
    var supportsSilent: Bool
    var supportsSecretEnvVars: Bool
    var requiresAllowAllToolsForPrompt: Bool

    static let conservative = CopilotCLICapabilities(
        supportsOutputFormatJSON: false,
        supportsStreamingFlag: false,
        supportsNoAskUser: false,
        supportsSilent: false,
        supportsSecretEnvVars: false,
        requiresAllowAllToolsForPrompt: true
    )

    init(helpText: String) {
        supportsOutputFormatJSON = helpText.contains("--output-format")
        supportsStreamingFlag = helpText.contains("--stream")
        supportsNoAskUser = helpText.contains("--no-ask-user")
        supportsSilent = helpText.contains("--silent") || helpText.contains("-s,")
        supportsSecretEnvVars = helpText.contains("--secret-env-vars")
        requiresAllowAllToolsForPrompt = helpText.contains("required for\n                                      non-interactive mode")
            || helpText.contains("required for non-interactive mode")
    }

    private init(
        supportsOutputFormatJSON: Bool,
        supportsStreamingFlag: Bool,
        supportsNoAskUser: Bool,
        supportsSilent: Bool,
        supportsSecretEnvVars: Bool,
        requiresAllowAllToolsForPrompt: Bool
    ) {
        self.supportsOutputFormatJSON = supportsOutputFormatJSON
        self.supportsStreamingFlag = supportsStreamingFlag
        self.supportsNoAskUser = supportsNoAskUser
        self.supportsSilent = supportsSilent
        self.supportsSecretEnvVars = supportsSecretEnvVars
        self.requiresAllowAllToolsForPrompt = requiresAllowAllToolsForPrompt
    }
}

struct CopilotCLICommandPlan: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var parsesJSONLines: Bool
}

enum CopilotCLIRuntime {
    static let executableName = "copilot"

    static func detectPath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/copilot",
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
            "\(NSHomeDirectory())/.npm-global/bin/copilot"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [executableName]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path
    }

    static func capabilities(executablePath: String) -> CopilotCLICapabilities {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .conservative
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .conservative
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let help = String(data: data, encoding: .utf8) ?? ""
        return CopilotCLICapabilities(helpText: help)
    }

    static func channelHome() -> String {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(AppChannel.current.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Copilot", isDirectory: true)
        return appSupport.path
    }

    static func buildCommand(
        executablePath: String,
        prompt: String,
        model: String,
        workspacePath: String,
        additionalPaths: [String],
        permissionPolicy: PermissionPolicy,
        allowedTools: [String],
        timeoutSeconds: TimeInterval,
        capabilities: CopilotCLICapabilities,
        taskEnvironment: [String: String],
        copilotHome: String,
        providerEnvironment: [String: String] = [:]
    ) -> CopilotCLICommandPlan {
        var args = ["--prompt", prompt, "--model", model, "--no-color", "--log-level", "error"]

        if capabilities.supportsOutputFormatJSON {
            args += ["--output-format=json"]
        } else if capabilities.supportsSilent {
            args += ["--silent"]
        }

        if capabilities.supportsStreamingFlag {
            args += ["--stream=on"]
        }

        if capabilities.supportsNoAskUser {
            args += ["--no-ask-user"]
        }

        let uniquePaths = Array(Set(additionalPaths.filter { !$0.isEmpty && $0 != workspacePath })).sorted()
        for path in uniquePaths {
            args += ["--add-dir", path]
        }

        let permissionArgs = copilotPermissionArguments(
            policy: permissionPolicy,
            allowedTools: allowedTools,
            requiresAllowAllToolsForPrompt: capabilities.requiresAllowAllToolsForPrompt
        )
        args += permissionArgs

        if capabilities.supportsSecretEnvVars {
            let secretKeys = Array(Set(Array(taskEnvironment.keys) + [
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "COPILOT_PROVIDER_API_KEY",
                "GITHUB_TOKEN",
                "GH_TOKEN",
                "COPILOT_GITHUB_TOKEN"
            ])).sorted()
            if !secretKeys.isEmpty {
                args += ["--secret-env-vars", secretKeys.joined(separator: ",")]
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:\(NSHomeDirectory())/.astra/tools"
        env["COPILOT_HOME"] = copilotHome
        env["NO_COLOR"] = "1"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        for (key, value) in taskEnvironment {
            env[key] = value
        }
        for (key, value) in providerEnvironment {
            env[key] = value
        }

        return CopilotCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: capabilities.supportsOutputFormatJSON
        )
    }

    static func copilotPermissionArguments(
        policy: PermissionPolicy,
        allowedTools: [String],
        requiresAllowAllToolsForPrompt: Bool
    ) -> [String] {
        switch policy {
        case .autonomous:
            if requiresAllowAllToolsForPrompt {
                return ["--allow-all-tools", "--allow-all-paths"]
            }
            return [
                "--allow-tool",
                "read,write,shell(git:*),shell(swift:*),shell(./script/*),shell(xcodebuild:*)"
            ]
        case .restricted:
            let mapped = allowedTools.isEmpty
                ? ["read", "shell(git status)", "shell(git diff)", "shell(git log)"]
                : allowedTools.flatMap(mapClaudeToolToCopilotPermissions)
            guard !mapped.isEmpty else { return [] }
            return ["--allow-tool", Array(Set(mapped)).sorted().joined(separator: ",")]
        case .interactive:
            return []
        }
    }

    private static func mapClaudeToolToCopilotPermissions(_ tool: String) -> [String] {
        switch tool.lowercased() {
        case "read", "grep", "glob", "ls":
            return ["read"]
        case "write", "edit", "multiedit":
            return ["write"]
        case "bash":
            return ["shell(git:*)", "shell(swift:*)", "shell(./script/*)"]
        default:
            if tool.hasPrefix("shell(") || tool == "read" || tool == "write" {
                return [tool]
            }
            return []
        }
    }
}
