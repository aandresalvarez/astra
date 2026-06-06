import Foundation
import ASTRACore

struct OpenCodeCLICommandPlan: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var parsesJSONLines: Bool
}

enum OpenCodeCLIRuntime {
    static let executableName = "opencode"
    static let bundledModelNames = [
        "opencode/big-pickle",
        "opencode/deepseek-v4-flash-free",
        "opencode/mimo-v2.5-free",
        "opencode/minimax-m3-free",
        "opencode/nemotron-3-ultra-free"
    ]

    static func detectPath() -> String {
        RuntimePathResolver.detectOpenCodePath()
    }

    static func defaultModelName() -> String {
        bundledModelNames.first ?? "opencode/big-pickle"
    }

    static func availableModelNames() -> [String] {
        bundledModelNames
    }

    static func buildCommand(
        executablePath: String,
        prompt: String,
        model: String,
        workspacePath: String,
        additionalPaths: [String],
        permissionPolicy: PermissionPolicy,
        timeoutSeconds _: TimeInterval,
        taskEnvironment: [String: String],
        pathPrefix: [String] = [],
        includeAstraToolsPath: Bool = false
    ) -> OpenCodeCLICommandPlan {
        let providerModel = resolvedModelName(model)
        let launchDirectory = executionDirectory(
            workspacePath: workspacePath,
            additionalPaths: additionalPaths
        )
        var args = [
            "run",
            "--format", "json",
            "--dir", launchDirectory,
            "--model", providerModel
        ]
        args += permissionArguments(policy: permissionPolicy)
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

        return OpenCodeCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: true
        )
    }

    static func executionDirectory(workspacePath: String, additionalPaths: [String]) -> String {
        let candidates = ([workspacePath] + additionalPaths)
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let gitWorkspace = candidates.first(where: isGitBackedDirectory) {
            return gitWorkspace
        }
        return workspacePath
    }

    static func permissionArguments(policy: PermissionPolicy) -> [String] {
        switch policy {
        case .autonomous:
            return ["--dangerously-skip-permissions"]
        case .restricted, .interactive:
            return []
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

    static func modelNames(executablePath: String) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: executablePath),
              let output = runProbe(executablePath: executablePath, args: ["models"], timeoutSeconds: 8) else {
            return nil
        }
        let models = parseModelNames(output)
        return models.isEmpty ? nil : models
    }

    static func parseModelNames(_ output: String) -> [String] {
        let models = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && line.contains("/")
                    && !line.hasPrefix("{")
                    && !line.hasPrefix("[")
            }
        return RuntimeModelAvailability.cleanProviderModels(models)
    }

    static func parseEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        parsesJSONLines
            ? OpenCodeStreamEventParser.parseAll(line: line)
            : OpenCodeStreamEventParser.parsePlainText(line: line)
    }

    static func parseAgentEvents(line: String, parsesJSONLines: Bool) -> [AgentEvent] {
        parsesJSONLines
            ? OpenCodeStreamEventParser.parseAgentEvents(line: line)
            : OpenCodeStreamEventParser.parsePlainTextAgentEvents(line: line, appendingNewline: true)
    }

    static func blockingMessage(line: String, parsesJSONLines: Bool) -> String? {
        if parsesJSONLines, lineParsesAsJSON(line) {
            return nil
        }
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("opencode auth login")
            || lower.contains("not logged in")
            || lower.contains("authentication")
            || lower.contains("api key") {
            return "OpenCode CLI needs an authenticated provider before ASTRA can run it. Open a terminal and run `opencode auth login`, then retry.\n"
        }
        if lower.contains("permission") || lower.contains("approval") {
            return "OpenCode CLI is waiting for an approval ASTRA cannot answer directly: \(line)\n"
        }
        return nil
    }

    static func extractUtilityText(from output: String) -> String {
        var pieces: [String] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            for event in OpenCodeStreamEventParser.parseAgentEvents(line: line) {
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

    private static func lineParsesAsJSON(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isGitBackedDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--is-inside-work-tree"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
