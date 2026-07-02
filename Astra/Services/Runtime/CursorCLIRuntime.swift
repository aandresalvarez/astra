import Foundation
import ASTRACore

struct CursorCLICommandPlan: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var parsesJSONLines: Bool
}

enum CursorCLIRuntime {
    static let executableName = "cursor-agent"
    static let bundledModelNames = [
        "composer-2.5-fast",
        "composer-2.5",
        "gpt-5.5-medium",
        "gpt-5.5-high",
        "gpt-5.4-medium",
        "gpt-5.4-mini-medium",
        "gpt-5.3-codex",
        "claude-4-sonnet"
    ]

    static func detectPath() -> String {
        RuntimePathResolver.detectCursorPath()
    }

    static func defaultModelName() -> String {
        bundledModelNames.first ?? "composer-2.5-fast"
    }

    static func availableModelNames() -> [String] {
        bundledModelNames
    }

    static func buildCommand(
        executablePath: String,
        prompt: String,
        model: String,
        workspacePath: String,
        additionalPaths _: [String],
        permissionPolicy: PermissionPolicy,
        timeoutSeconds _: TimeInterval,
        taskEnvironment: [String: String],
        pathPrefix: [String] = [],
        includeAstraToolsPath: Bool = false,
        permissionArguments: [String]? = nil
    ) -> CursorCLICommandPlan {
        let providerModel = resolvedModelName(model)
        var args = [
            "--print",
            "--output-format", "stream-json",
            "--trust",
            "--workspace", workspacePath,
            "--model", providerModel
        ]
        args += permissionArguments ?? cursorPermissionArguments(policy: permissionPolicy)
        args.append(prompt)

        var extraVars: [String: String] = [
            "NO_COLOR": "1"
        ]
        let parentTerm = ProcessInfo.processInfo.environment["TERM"]
        extraVars["TERM"] = parentTerm ?? "xterm-256color"
        for (key, value) in taskEnvironment {
            extraVars[key] = value
        }

        let additionalPathPrefix = includeAstraToolsPath
            ? pathPrefix + [RuntimePathResolver.astraToolsPath]
            : pathPrefix
        let env = RuntimeProcessEnvironment.enriched(
            additionalPaths: additionalPathPrefix,
            extraVariables: extraVars
        )

        return CursorCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: true
        )
    }

    static func cursorPermissionArguments(policy: PermissionPolicy) -> [String] {
        switch policy {
        case .autonomous:
            return ["--force", "--sandbox", "disabled"]
        case .restricted:
            return ["--sandbox", "enabled"]
        case .interactive:
            return ["--mode", "ask", "--sandbox", "enabled"]
        }
    }

    static func resolvedModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "default" {
            return defaultModelName()
        }
        return trimmed
    }

    static func versionSummary(executablePath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return nil
        }
        return runProbe(executablePath: executablePath, args: ["--version"], timeoutSeconds: 2)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func modelDetails(executablePath: String) -> [RuntimeModelDetail]? {
        guard FileManager.default.isExecutableFile(atPath: executablePath),
              let output = runProbe(executablePath: executablePath, args: ["models"], timeoutSeconds: 8) else {
            return nil
        }
        let models = parseModelDetails(output)
        return models.isEmpty ? nil : models
    }

    /// Parses `cursor-agent models` output: one `id - Display Name` pair per
    /// line. Trailing "(default)"/"(current)" markers describe the CLI's own
    /// selection state, not the model, so they are stripped from the name.
    static func parseModelDetails(_ output: String) -> [RuntimeModelDetail] {
        var models: [RuntimeModelDetail] = []
        for rawLine in output.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  line != "Available models",
                  !line.hasPrefix("Tip:"),
                  let separator = line.range(of: " - ") else {
                continue
            }
            let id = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            var name = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in ["(default)", "(current)"] where name.hasSuffix(marker) {
                name = String(name.dropLast(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            models.append(RuntimeModelDetail(value: id, displayName: name.isEmpty ? nil : name))
        }
        return RuntimeModelAvailability.cleanProviderModelDetails(models)
    }

    static func parseEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        parsesJSONLines
            ? CursorStreamEventParser.parseAll(line: line)
            : CursorStreamEventParser.parsePlainText(line: line)
    }

    static func parseAgentEvents(line: String, parsesJSONLines: Bool) -> [AgentEvent] {
        parsesJSONLines
            ? CursorStreamEventParser.parseAgentEvents(line: line)
            : CursorStreamEventParser.parsePlainTextAgentEvents(line: line, appendingNewline: true)
    }

    static func blockingMessage(line: String, parsesJSONLines: Bool) -> String? {
        if parsesJSONLines, lineParsesAsJSON(line) {
            return nil
        }
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("cursor-agent login") || lower.contains("not logged in") || lower.contains("authentication") {
            return "Cursor CLI needs an authenticated session before ASTRA can run it. Open a terminal and run `cursor-agent login`, then retry.\n"
        }
        if lower.contains("trust") && lower.contains("workspace") {
            return "Cursor CLI is waiting for workspace trust. ASTRA launches Cursor with `--trust`; retry after checking the workspace path.\n"
        }
        if lower.contains("approval") || lower.contains("permission") {
            return "Cursor CLI is waiting for an approval ASTRA cannot answer directly: \(line)\n"
        }
        return nil
    }

    private static func lineParsesAsJSON(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func extractUtilityText(from output: String) -> String {
        var pieces: [String] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            for event in CursorStreamEventParser.parseAgentEvents(line: line) {
                switch event {
                case .text(let text):
                    pieces.append(text)
                case .completed(let summary):
                    if let summary, !summary.isEmpty {
                        pieces.append(summary)
                    }
                case .failed(let message):
                    pieces.append(message)
                default:
                    continue
                }
            }
        }
        let joined = pieces.joined()
        return joined.isEmpty ? output : joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runProbe(executablePath: String, args: [String], timeoutSeconds: TimeInterval) -> String? {
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
}
