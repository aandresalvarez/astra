import Foundation
import ASTRACore

struct CodexCLICommandPlan: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var parsesJSONLines: Bool
}

enum CodexCLIRuntime {
    static let executableName = "codex"
    // Codex CLI has no model enumeration command (`--model` is free-form),
    // so this curated list is the only source. Refresh it from
    // https://developers.openai.com/codex/models when OpenAI ships models.
    static let bundledModelNames = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex-spark"
    ]

    static func detectPath() -> String {
        RuntimePathResolver.detectCodexPath()
    }

    static func defaultModelName() -> String {
        bundledModelNames.first ?? "gpt-5.5"
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
        providerHomeDirectory: String = "",
        pathPrefix: [String] = [],
        includeAstraToolsPath: Bool = false,
        allowExternalFileReadsForSSH: Bool = false,
        resumeSessionID: String? = nil
    ) -> CodexCLICommandPlan {
        let providerModel = resolvedModelName(model)
        // No `--ephemeral`: native continuation needs the session persisted so a
        // follow-up turn can `exec resume` it. CODEX_HOME scoping (below) keeps
        // ASTRA-run sessions out of the user's own Codex history when configured.
        let trimmedResumeSessionID = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usesResume = !trimmedResumeSessionID.isEmpty
        var args = usesResume ? ["exec", "resume"] : ["exec"]

        if usesResume {
            args += [
                "--json",
                "--ignore-user-config",
                "--ignore-rules",
                "--model", providerModel
            ]
            args += codexResumePermissionArguments(policy: permissionPolicy)
            if allowExternalFileReadsForSSH, permissionPolicy != .autonomous {
                args += ["--config", "sandbox_permissions=[\"disk-full-read-access\"]"]
            }
            args.append("--skip-git-repo-check")
            args.append(trimmedResumeSessionID)
        } else {
            args += [
                "--json",
                "--color", "never",
                "--ignore-user-config",
                "--ignore-rules",
                "--model", providerModel,
                "--cd", workspacePath
            ]

            let uniquePaths = Array(Set(additionalPaths.filter { !$0.isEmpty && $0 != workspacePath })).sorted()
            for path in uniquePaths {
                args += ["--add-dir", path]
            }

            args += codexPermissionArguments(policy: permissionPolicy)
            if allowExternalFileReadsForSSH, permissionPolicy != .autonomous {
                args += ["--config", "sandbox_permissions=[\"disk-full-read-access\"]"]
            }
            args.append("--skip-git-repo-check")
        }
        args.append(prompt)

        var extraVars: [String: String] = [
            "NO_COLOR": "1"
        ]
        let parentTerm = ProcessInfo.processInfo.environment["TERM"]
        extraVars["TERM"] = parentTerm ?? "xterm-256color"
        for (key, value) in taskEnvironment {
            extraVars[key] = value
        }
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            extraVars["CODEX_HOME"] = trimmedHome
        }

        let additionalPathPrefix = includeAstraToolsPath
            ? pathPrefix + [RuntimePathResolver.astraToolsPath]
            : pathPrefix
        let env = RuntimeProcessEnvironment.enriched(
            additionalPaths: additionalPathPrefix,
            extraVariables: extraVars
        )

        return CodexCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: true
        )
    }

    static func codexPermissionArguments(policy: PermissionPolicy) -> [String] {
        switch policy {
        case .autonomous:
            return ["--dangerously-bypass-approvals-and-sandbox"]
        case .restricted:
            return ["--sandbox", "workspace-write"]
        case .interactive:
            return ["--sandbox", "read-only"]
        }
    }

    static func codexResumePermissionArguments(policy: PermissionPolicy) -> [String] {
        // `codex exec resume` rejects `-s/--sandbox` (it's an `exec`-only flag),
        // so preserve the run-phase sandbox mode via the supported `-c` config
        // override instead. Without this a restricted (workspace-write) task would
        // silently fall back to codex's default sandbox on a resumed turn,
        // diverging from `codexPermissionArguments` above. The value spellings
        // match the `--sandbox` enum (`sandbox_mode` config key).
        switch policy {
        case .autonomous:
            return ["--dangerously-bypass-approvals-and-sandbox"]
        case .restricted:
            return ["-c", "sandbox_mode=\"workspace-write\""]
        case .interactive:
            return ["-c", "sandbox_mode=\"read-only\""]
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
        return probeVersion(executablePath: executablePath, args: ["--version"])
    }

    static func parseEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        parsesJSONLines
            ? CodexStreamEventParser.parseAll(line: line)
            : CodexStreamEventParser.parsePlainText(line: line)
    }

    static func parseAgentEvents(line: String, parsesJSONLines: Bool) -> [AgentEvent] {
        parsesJSONLines
            ? CodexStreamEventParser.parseAgentEvents(line: line)
            : CodexStreamEventParser.parsePlainTextAgentEvents(line: line, appendingNewline: true)
    }

    static func blockingMessage(line: String, parsesJSONLines: Bool) -> String? {
        if parsesJSONLines {
            return nil
        }
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("codex login") || lower.contains("not logged in") || lower.contains("authentication") {
            return "Codex CLI needs an authenticated session before ASTRA can run it. Open a terminal and run `codex login`, then retry.\n"
        }
        if lower.contains("approval") || lower.contains("permission") {
            return "Codex CLI is waiting for an approval ASTRA cannot answer directly: \(line)\n"
        }
        return nil
    }

    static func directoriesToCreate(
        providerHomeDirectory: String,
        environment: [String: String] = [:]
    ) -> [String] {
        let trimmed = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return [trimmed]
        }
        let inheritedHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return inheritedHome.isEmpty ? [] : [inheritedHome]
    }

    static func sandboxReadablePaths(
        providerHomeDirectory: String,
        environment: [String: String],
        processHomeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        var paths: [String] = []
        if let codexHome = codexHomeDirectory(
            providerHomeDirectory: providerHomeDirectory,
            environment: environment,
            processHomeDirectory: processHomeDirectory
        ) {
            paths.append(codexHome)
        }
        paths.append("/etc/codex")
        #if os(macOS)
        paths.append(contentsOf: [
            "/Library/Managed Preferences",
            "/Library/Preferences"
        ])
        #endif
        return uniqueNonEmpty(paths)
    }

    private static func codexHomeDirectory(
        providerHomeDirectory: String,
        environment: [String: String],
        processHomeDirectory: String
    ) -> String? {
        let configuredHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredHome.isEmpty {
            return configuredHome
        }
        let inheritedCodexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !inheritedCodexHome.isEmpty {
            return inheritedCodexHome
        }
        let inheritedHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let home = inheritedHome.isEmpty
            ? processHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            : inheritedHome
        return home.isEmpty ? nil : (home as NSString).appendingPathComponent(".codex")
    }

    private static func uniqueNonEmpty(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { rawPath in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    static func extractUtilityText(from output: String) -> String {
        var pieces: [String] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            for event in CodexStreamEventParser.parseAgentEvents(line: line) {
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
        return output
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
