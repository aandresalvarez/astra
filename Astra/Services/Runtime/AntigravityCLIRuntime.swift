import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct AntigravityCLICommandPlan: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var parsesJSONLines: Bool
    var diagnosticLogPath: String?
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
        nil
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

    static func modelNames(executablePath: String) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: executablePath),
              let output = runProbe(executablePath: executablePath, args: ["models"], timeoutSeconds: 8) else {
            return nil
        }
        let models = parseModelNames(output)
        return models.isEmpty ? nil : models
    }

    /// Parses `agy models` output: one model per line. The strings double as
    /// the `--model` value and the display name; parentheticals like
    /// "(Thinking)" or "(Low)" are part of the model identity, not selection
    /// markers, so lines are kept verbatim.
    static func parseModelNames(_ output: String) -> [String] {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                return !lower.hasPrefix("available models") && !lower.hasPrefix("tip:")
            }
        return RuntimeModelAvailability.cleanProviderModels(lines)
    }

    static func configuredModel(settingsURL: URL = settingsURL()) -> String? {
        guard let data = readProviderFile(at: settingsURL),
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
        if let data = readProviderFile(at: settingsURL),
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
        includeAstraToolsPath: Bool = false,
        diagnosticLogPath: String? = nil,
        permissionArguments: [String]
    ) -> AntigravityCLICommandPlan {
        var args = [
            "--print",
            prompt,
            "--print-timeout",
            printTimeoutArgument(timeoutSeconds)
        ]
        if let diagnosticLogPath,
           !diagnosticLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--log-file", diagnosticLogPath]
        }

        let uniquePaths = Array(Set(additionalPaths.filter { !$0.isEmpty && $0 != workspacePath })).sorted()
        for path in uniquePaths {
            args += ["--add-dir", path]
        }
        args += permissionArguments

        var extraVars: [String: String] = [
            "NO_COLOR": "1",
            "AGY_CLI_HIDE_ACCOUNT_INFO": "1",
        ]
        let parentTerm = ProcessInfo.processInfo.environment["TERM"]
        extraVars["TERM"] = parentTerm ?? "xterm-256color"
        for (key, value) in taskEnvironment {
            extraVars[key] = value
        }
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            extraVars["HOME"] = trimmedHome
        }
        let env = RuntimeProcessEnvironment.enriched(
            additionalPaths: pathPrefix,
            extraVariables: extraVars
        )

        return AntigravityCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: false,
            diagnosticLogPath: diagnosticLogPath
        )
    }

    static func diagnosticLogPath(task: AgentTask, runID: UUID) -> String? {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return nil }
        let diagnostics = (taskFolder as NSString).appendingPathComponent("diagnostics")
        let shortRunID = String(runID.uuidString.prefix(8))
        return (diagnostics as NSString).appendingPathComponent("antigravity-\(shortRunID).log")
    }

    static func diagnosticLogDirectory(for logPath: String?) -> String? {
        guard let logPath,
              !logPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (logPath as NSString).deletingLastPathComponent
    }

    struct DiagnosticSummary: Equatable {
        var primaryCode: String
        var message: String
        var findings: [String]
        var evidence: String
        var logPath: String

        var auditFields: [String: String] {
            [
                "provider_failure_category": primaryCode,
                "provider_diagnostic_log": logPath,
                "provider_diagnostic_findings": findings.joined(separator: ","),
                "provider_diagnostic_evidence": evidence
            ]
        }
    }

    static func diagnosticSummary(logPath: String?) -> DiagnosticSummary? {
        guard let logPath,
              let data = readProviderFile(at: URL(fileURLWithPath: logPath)),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return diagnosticSummary(logText: raw, logPath: logPath)
    }

    private static func readProviderFile(at url: URL) -> Data? {
        try? HostFileAccessBroker().readData(
            at: url,
            intent: .astraManagedStorage(root: url.deletingLastPathComponent())
        )
    }

    static func diagnosticSummary(logText: String, logPath: String) -> DiagnosticSummary? {
        let lower = logText.lowercased()
        var findings: [String] = []
        var evidenceLines: [String] = []

        func addFinding(_ code: String, patterns: [String]) {
            guard patterns.contains(where: { lower.contains($0) }) else { return }
            findings.append(code)
            if let line = firstLine(in: logText, matching: patterns) {
                evidenceLines.append(line)
            }
        }

        addFinding("quota_exhausted", patterns: [
            "resource_exhausted",
            "exhausted your capacity",
            "capacity on this model",
            "quota will reset"
        ])
        addFinding("account_ineligible", patterns: ["account ineligible", "not eligible for antigravity"])
        if !antigravityLogShowsSuccessfulAuth(logText) {
            addFinding("auth_required", patterns: ["not logged into antigravity", "authentication required"])
        }
        addFinding("malformed_mcp_config", patterns: ["mcp_config.json", "unexpected end of json input"])

        guard !findings.isEmpty else { return nil }
        let uniqueFindings = uniqueStrings(findings)
        let primary = uniqueFindings.first ?? "antigravity_hidden_failure"
        let evidence = uniqueStrings(evidenceLines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = diagnosticMessage(primary: primary, findings: uniqueFindings, evidence: evidence)
        return DiagnosticSummary(
            primaryCode: primary,
            message: message,
            findings: uniqueFindings,
            evidence: String(RuntimeReadinessRedactor.redacted(evidence).prefix(500)),
            logPath: logPath
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

    private static func runProbe(executablePath: String, args: [String], timeoutSeconds: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.environment = RuntimeProcessEnvironment.enriched(extraVariables: ["NO_COLOR": "1"])

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

        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
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
        return output
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func firstLine(in text: String, matching patterns: [String]) -> String? {
        text.components(separatedBy: .newlines).first { line in
            let lower = line.lowercased()
            return patterns.contains { lower.contains($0) }
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func antigravityLogShowsSuccessfulAuth(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("oauth: authenticated successfully")
            || lower.contains("silent auth succeeded")
            || lower.contains("authenticated via keyring")
    }

    private static func diagnosticMessage(primary: String, findings: [String], evidence: String) -> String {
        let primaryMessage: String
        switch primary {
        case "quota_exhausted":
            let reset = quotaResetText(from: evidence)
            let resetText = reset.map { " \($0)." } ?? ""
            primaryMessage = "Antigravity quota is exhausted for the selected model.\(resetText) Wait for the quota reset, choose another eligible Antigravity account/model, or switch providers."
        case "account_ineligible":
            primaryMessage = "The authenticated Google account is not eligible for Antigravity. Sign in with an eligible account or switch providers."
        case "auth_required":
            primaryMessage = "Antigravity is not authenticated for non-interactive use. Run `agy` in Terminal, complete Google Sign-In, then retry."
        case "malformed_mcp_config":
            primaryMessage = "Antigravity has a malformed local MCP config. Repair or remove `~/.gemini/config/mcp_config.json`, then retry."
        default:
            primaryMessage = "Antigravity logged a hidden provider failure."
        }
        let secondary = findings.dropFirst()
        let secondaryText = secondary.isEmpty ? "" : " Additional findings: \(secondary.joined(separator: ", "))."
        let evidenceText = evidence.isEmpty ? "" : " Evidence: \(String(RuntimeReadinessRedactor.redacted(evidence).prefix(300)))"
        return primaryMessage + secondaryText + evidenceText
    }

    private static func quotaResetText(from evidence: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)quota will reset after\s+([A-Za-z0-9:._ -]+?)(?:\.|$)"#
        ) else {
            return nil
        }
        let range = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
        guard let match = regex.firstMatch(in: evidence, range: range),
              match.numberOfRanges > 1,
              let resetRange = Range(match.range(at: 1), in: evidence) else {
            return nil
        }
        let reset = evidence[resetRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return reset.isEmpty ? nil : "Quota will reset after \(reset)"
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
}
