import Foundation
import ASTRACore

struct CopilotCLICapabilities: Equatable {
    var supportsOutputFormatJSON: Bool
    var supportsStreamingFlag: Bool
    var supportsNoAskUser: Bool
    var supportsSilent: Bool
    var supportsSecretEnvVars: Bool
    var supportsAllowAll: Bool
    var supportsAllowAllTools: Bool
    var supportsAllowAllPaths: Bool
    var supportsAllowAllURLs: Bool
    var requiresAllowAllToolsForPrompt: Bool
    var supportsNoCustomInstructions: Bool

    static let conservative = CopilotCLICapabilities(
        supportsOutputFormatJSON: false,
        supportsStreamingFlag: false,
        supportsNoAskUser: false,
        supportsSilent: false,
        supportsSecretEnvVars: false,
        supportsAllowAll: false,
        supportsAllowAllTools: false,
        supportsAllowAllPaths: false,
        supportsAllowAllURLs: false,
        requiresAllowAllToolsForPrompt: true,
        supportsNoCustomInstructions: false
    )

    init(helpText: String) {
        supportsOutputFormatJSON = Self.hasOption("--output-format", in: helpText)
        supportsStreamingFlag = Self.hasOption("--stream", in: helpText)
        supportsNoAskUser = Self.hasOption("--no-ask-user", in: helpText)
        supportsSilent = Self.hasOption("--silent", in: helpText) || helpText.contains("-s,")
        supportsSecretEnvVars = Self.hasOption("--secret-env-vars", in: helpText)
        supportsAllowAll = Self.hasOption("--allow-all", in: helpText)
        supportsAllowAllTools = Self.hasOption("--allow-all-tools", in: helpText)
        supportsAllowAllPaths = Self.hasOption("--allow-all-paths", in: helpText)
        supportsAllowAllURLs = Self.hasOption("--allow-all-urls", in: helpText)
        requiresAllowAllToolsForPrompt = helpText.contains("required for\n                                      non-interactive mode")
            || helpText.contains("required for non-interactive mode")
        supportsNoCustomInstructions = Self.hasOption("--no-custom-instructions", in: helpText)
    }

    private init(
        supportsOutputFormatJSON: Bool,
        supportsStreamingFlag: Bool,
        supportsNoAskUser: Bool,
        supportsSilent: Bool,
        supportsSecretEnvVars: Bool,
        supportsAllowAll: Bool,
        supportsAllowAllTools: Bool,
        supportsAllowAllPaths: Bool,
        supportsAllowAllURLs: Bool,
        requiresAllowAllToolsForPrompt: Bool,
        supportsNoCustomInstructions: Bool
    ) {
        self.supportsOutputFormatJSON = supportsOutputFormatJSON
        self.supportsStreamingFlag = supportsStreamingFlag
        self.supportsNoAskUser = supportsNoAskUser
        self.supportsSilent = supportsSilent
        self.supportsSecretEnvVars = supportsSecretEnvVars
        self.supportsAllowAll = supportsAllowAll
        self.supportsAllowAllTools = supportsAllowAllTools
        self.supportsAllowAllPaths = supportsAllowAllPaths
        self.supportsAllowAllURLs = supportsAllowAllURLs
        self.requiresAllowAllToolsForPrompt = requiresAllowAllToolsForPrompt
        self.supportsNoCustomInstructions = supportsNoCustomInstructions
    }

    private static func hasOption(_ option: String, in helpText: String) -> Bool {
        helpText
            .split(whereSeparator: { $0.isWhitespace })
            .contains { rawToken in
                let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
                return token == option
                    || token.hasPrefix("\(option)=")
                    || token.hasPrefix("\(option)[")
            }
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
        RuntimePathResolver.detectCopilotPath()
    }

    static func capabilities(executablePath: String) -> CopilotCLICapabilities {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .conservative
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["help"]
        process.environment = RuntimeProcessEnvironment.enriched()
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

    static func versionSummary(executablePath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return nil
        }
        for args in [["--version"], ["version"]] {
            if let version = probeVersion(executablePath: executablePath, args: args) {
                return version
            }
        }
        return nil
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
        providerEnvironment: [String: String] = [:],
        pathPrefix: [String] = [],
        includeAstraToolsPath: Bool = false,
        localToolCommands: [String] = [],
        runtimeSupportTools: [String] = [],
        disableCustomInstructions: Bool = false
    ) -> CopilotCLICommandPlan {
        var args = ["--prompt", prompt, "--model", model, "--no-color", "--log-level", "error"]

        // Self-contained helper prompts (commit messages, PR drafts, etc.) must not
        // inherit the repository's AGENTS.md operating guide, which otherwise turns a
        // single-shot summarization into a full agentic workflow that never converges.
        if disableCustomInstructions, capabilities.supportsNoCustomInstructions {
            args += ["--no-custom-instructions"]
        }

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
            localToolCommands: localToolCommands,
            runtimeSupportTools: runtimeSupportTools,
            supportsAllowAll: capabilities.supportsAllowAll,
            supportsAllowAllTools: capabilities.supportsAllowAllTools,
            supportsAllowAllPaths: capabilities.supportsAllowAllPaths,
            supportsAllowAllURLs: capabilities.supportsAllowAllURLs,
            requiresAllowAllToolsForPrompt: capabilities.requiresAllowAllToolsForPrompt
        )
        args += permissionArgs

        if capabilities.supportsSecretEnvVars {
            let secretKeys = copilotSecretEnvironmentKeys(
                taskEnvironment: taskEnvironment,
                providerEnvironment: providerEnvironment
            )
            if !secretKeys.isEmpty {
                args += ["--secret-env-vars", secretKeys.joined(separator: ",")]
            }
        }

        var extraVars: [String: String] = [
            "COPILOT_HOME": copilotHome,
            "NO_COLOR": "1",
        ]
        let parentTerm = ProcessInfo.processInfo.environment["TERM"]
        extraVars["TERM"] = parentTerm ?? "xterm-256color"
        for (key, value) in taskEnvironment {
            extraVars[key] = value
        }
        for (key, value) in providerEnvironment {
            extraVars[key] = value
        }
        let env = RuntimeProcessEnvironment.enriched(
            additionalPaths: pathPrefix,
            extraVariables: extraVars
        )

        return CopilotCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: capabilities.supportsOutputFormatJSON
        )
    }

    private static func uniqueNonEmptyPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    static func copilotPermissionArguments(
        policy: PermissionPolicy,
        allowedTools: [String],
        localToolCommands: [String] = [],
        runtimeSupportTools: [String] = [],
        supportsAllowAll: Bool = false,
        supportsAllowAllTools: Bool = false,
        supportsAllowAllPaths: Bool = false,
        supportsAllowAllURLs: Bool = false,
        requiresAllowAllToolsForPrompt: Bool
    ) -> [String] {
        let localToolPermissions = shouldAddLocalToolPermissions(policy: policy, allowedTools: allowedTools)
            ? copilotShellPermissions(forLocalToolCommands: localToolCommands)
            : []
        let supportToolPermissions = Array(Set(runtimeSupportTools.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        switch policy {
        case .autonomous:
            if supportsAllowAll {
                return ["--allow-all"]
            }
            if supportsAllowAllTools || requiresAllowAllToolsForPrompt {
                var args = ["--allow-all-tools"]
                if supportsAllowAllPaths {
                    args.append("--allow-all-paths")
                }
                if supportsAllowAllURLs {
                    args.append("--allow-all-urls")
                }
                return args
            }
            return [
                "--allow-tool",
                "read",
                "write",
                "shell(git:*)",
                "shell(swift:*)",
                "shell(./script/*)",
                "shell(xcodebuild:*)"
            ] + localToolPermissions
        case .restricted:
            let mapped = (allowedTools.isEmpty
                ? ["read", "shell(git status)", "shell(git diff)", "shell(git log)"]
                : allowedTools.flatMap(mapClaudeToolToCopilotPermissions)) + localToolPermissions + supportToolPermissions
            guard !mapped.isEmpty else { return [] }
            return ["--allow-tool"] + Array(Set(mapped)).sorted()
        case .interactive:
            return []
        }
    }

    static func copilotSecretEnvironmentKeys(
        taskEnvironment: [String: String],
        providerEnvironment: [String: String] = [:],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let taskKeys = Set(taskEnvironment.keys)
        let providerSecretKeys: Set<String> = [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "COPILOT_PROVIDER_API_KEY",
            "GITHUB_TOKEN",
            "GH_TOKEN",
            "COPILOT_GITHUB_TOKEN"
        ]
        let candidates = providerSecretKeys.union(providerEnvironment.keys)
        return candidates
            .filter { !taskKeys.contains($0) }
            .filter { key in
                let value = providerEnvironment[key] ?? processEnvironment[key] ?? ""
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted()
    }

    private static func shouldAddLocalToolPermissions(policy: PermissionPolicy, allowedTools: [String]) -> Bool {
        if policy == .autonomous {
            return true
        }
        return allowedTools.contains { tool in
            tool.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Bash") == .orderedSame
        }
    }

    static func copilotShellPermissions(forLocalToolCommands commands: [String]) -> [String] {
        Array(Set(commands.compactMap(copilotShellPermission(forLocalToolCommand:)))).sorted()
    }

    private static func copilotShellPermission(forLocalToolCommand command: String) -> String? {
        guard let executable = shellExecutableToken(command) else { return nil }
        return "shell(\(executable):*)"
    }

    private static func shellExecutableToken(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let executable = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !executable.isEmpty else { return nil }
        guard executable.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r)")) == nil else { return nil }
        return executable
    }

    private static func mapClaudeToolToCopilotPermissions(_ tool: String) -> [String] {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        switch lower {
        case "read", "grep", "glob", "ls":
            return ["read"]
        case "write", "edit", "multiedit":
            return ["write"]
        case "bash":
            return ["shell(git:*)", "shell(swift:*)", "shell(./script/*)"]
        case "webfetch", "websearch":
            return ["shell(curl:*)"]
        default:
            if lower.hasPrefix("bash("), lower.hasSuffix(")") {
                let patternStart = trimmed.index(trimmed.startIndex, offsetBy: "Bash(".count)
                let pattern = String(trimmed[patternStart..<trimmed.index(before: trimmed.endIndex)])
                return pattern.isEmpty ? [] : ["shell(\(pattern))"]
            }
            if lower.hasPrefix("shell(") || lower == "read" || lower == "write" {
                return [trimmed]
            }
            return []
        }
    }

    private static func probeVersion(executablePath: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.environment = RuntimeProcessEnvironment.enriched()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        let result = semaphore.wait(timeout: .now() + 2)
        guard result == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: outputData, encoding: .utf8) ?? "")
            + "\n"
            + (String(data: errorData, encoding: .utf8) ?? "")
        let firstLine = output
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else {
            return nil
        }
        return firstLine
    }
}
