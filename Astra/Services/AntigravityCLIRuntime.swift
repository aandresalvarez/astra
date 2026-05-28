import Foundation
import ASTRACore

struct AntigravityCLICommandPlan: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var parsesJSONLines: Bool
}

enum AntigravityCLIRuntime {
    static let executableName = "agy"
    static let bundledModelNames = [
        "Gemini 3.5 Flash (Low)",
        "Gemini 3.5 Flash",
        "Gemini 3.1 Pro (High)",
        "Gemini 3.1 Pro (Low)",
        "Gemini 3 Flash",
        "Claude Sonnet 4.6 (Thinking)",
        "Claude Opus 4.6 (Thinking)",
        "GPT-OSS-120B"
    ]

    static func detectPath() -> String {
        RuntimePathResolver.detectAntigravityPath()
    }

    static func versionSummary(executablePath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return nil
        }
        return probeVersion(executablePath: executablePath, args: ["--version"])
    }

    static func settingsURL(providerHomeDirectory: String = "") -> URL {
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmedHome.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: trimmedHome, isDirectory: true)
        return root
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func defaultModelName(settingsURL: URL = settingsURL()) -> String {
        configuredModel(settingsURL: settingsURL) ?? bundledModelNames.first ?? "default"
    }

    static func availableModelNames(settingsURL: URL = settingsURL()) -> [String] {
        uniqueModels([configuredModel(settingsURL: settingsURL)].compactMap { $0 } + bundledModelNames)
    }

    static func configuredModel(settingsURL: URL = settingsURL()) -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String else {
            return nil
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "default" ? nil : trimmed
    }

    static func resolvedModelName(_ model: String, settingsURL: URL = settingsURL()) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "default" {
            return defaultModelName(settingsURL: settingsURL)
        }
        return trimmed
    }

    @discardableResult
    static func applySelectedModel(
        _ model: String,
        settingsURL: URL = settingsURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        let selected = resolvedModelName(model, settingsURL: settingsURL)
        guard !selected.isEmpty else { return false }

        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        if object["model"] as? String == selected {
            return true
        }
        object["model"] = selected

        do {
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func buildCommand(
        executablePath: String,
        prompt: String,
        workspacePath: String,
        additionalPaths: [String],
        permissionPolicy: PermissionPolicy,
        timeoutSeconds: TimeInterval,
        taskEnvironment: [String: String],
        providerHomeDirectory: String = "",
        pathPrefix: [String] = [],
        includeAstraToolsPath: Bool = false
    ) -> AntigravityCLICommandPlan {
        var args = [
            "--print",
            prompt,
            "--print-timeout",
            printTimeoutArgument(timeoutSeconds)
        ]

        let uniquePaths = Array(Set(additionalPaths.filter { !$0.isEmpty && $0 != workspacePath })).sorted()
        for path in uniquePaths {
            args += ["--add-dir", path]
        }
        args += antigravityPermissionArguments(policy: permissionPolicy)

        var env = ProcessInfo.processInfo.environment
        let pathSuffix = includeAstraToolsPath
            ? RuntimePathResolver.agentPathSuffix
            : RuntimePathResolver.shellPathSuffix
        env["PATH"] = ([env["PATH"] ?? ""] + uniqueNonEmptyPaths(pathPrefix) + [pathSuffix])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["AGY_CLI_HIDE_ACCOUNT_INFO"] = "1"
        for (key, value) in taskEnvironment {
            env[key] = value
        }
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            env["HOME"] = trimmedHome
        }

        return AntigravityCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: false
        )
    }

    static func antigravityPermissionArguments(policy: PermissionPolicy) -> [String] {
        switch policy {
        case .autonomous:
            ["--dangerously-skip-permissions"]
        case .restricted, .interactive:
            ["--sandbox"]
        }
    }

    static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        parsePlainTextAgentEvents(line: line, appendingNewline: appendingNewline)
            .compactMap(AgentEventRecorder.parsedEvent(from:))
    }

    static func parsePlainTextAgentEvents(line: String, appendingNewline: Bool = false) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let prompt = plainTextPermissionPrompt(line: trimmed) {
            return [.permissionRequested(tool: prompt.tool, reason: prompt.reason)]
        }
        return [.text(text: appendingNewline ? line + "\n" : trimmed)]
    }

    static func blockingPlainTextMessage(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("authentication required") || lower.contains("please visit the url to log in") {
            return "Antigravity CLI needs an authenticated session before ASTRA can run it. Open a terminal and run `agy`, then complete Google Sign-In.\n"
        }
        guard plainTextPermissionPrompt(line: trimmed)?.isBlocking == true else {
            return nil
        }
        return "Antigravity CLI is waiting for a permission approval ASTRA cannot answer directly: \(trimmed)\n"
    }

    private static func printTimeoutArgument(_ timeoutSeconds: TimeInterval) -> String {
        "\(max(1, Int(timeoutSeconds)))s"
    }

    private static func uniqueNonEmptyPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func uniqueModels(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func plainTextPermissionPrompt(line: String) -> (tool: String, reason: String, isBlocking: Bool)? {
        let lower = line.lowercased()
        if lower.contains("allow access to these paths") && lower.contains("(y/n)") {
            return (tool: "WorkspaceAccess", reason: line, isBlocking: true)
        }
        if lower.contains("permission required") || lower.contains("requires permission") {
            return (tool: "ToolApproval", reason: line, isBlocking: lower.contains("(y/n)") || lower.contains("approve"))
        }
        if lower.contains("permission denied") {
            return (tool: "ToolApproval", reason: line, isBlocking: false)
        }
        return nil
    }

    private static func probeVersion(executablePath: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args

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

        guard semaphore.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = (String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            + "\n"
            + (String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        return output
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
