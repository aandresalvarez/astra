import Foundation
import ASTRACore

enum RuntimeReadinessState: String, Sendable, Equatable {
    case ready
    case warning
    case blocked
}

struct RuntimeReadinessCheck: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let detail: String
    let state: RuntimeReadinessState
    let remediation: String?
}

struct RuntimeReadinessReport: Sendable, Equatable {
    let checks: [RuntimeReadinessCheck]

    var state: RuntimeReadinessState {
        if checks.contains(where: { $0.state == .blocked }) { return .blocked }
        if checks.contains(where: { $0.state == .warning }) { return .warning }
        return .ready
    }

    var summary: String {
        switch state {
        case .ready:
            return "Ready to run tasks"
        case .warning:
            return "Usable, with follow-up recommended"
        case .blocked:
            return "Needs attention before tasks will run reliably"
        }
    }
}

struct RuntimeReadinessConfiguration: Sendable, Equatable {
    var runtime: AgentRuntimeID
    var claudePath: String
    var copilotPath: String
    var claudeProvider: ClaudeProvider
    var vertexProjectID: String
    var vertexRegion: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String
}

struct RuntimeReadinessService {
    private let runner: BinaryRunner
    private let timeout: TimeInterval
    private let detectExecutable: @Sendable (String) -> String
    private let isExecutable: @Sendable (String) -> Bool

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        timeout: TimeInterval = 5,
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimeReadinessService.defaultDetectExecutable($0)
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
    }

    func check(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessReport {
        switch configuration.runtime {
        case .claudeCode:
            return await checkClaude(configuration: configuration)
        case .copilotCLI:
            return await checkCopilot(configuration: configuration)
        }
    }

    // MARK: - Runtime checks

    private func checkClaude(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessReport {
        var checks: [RuntimeReadinessCheck] = []
        let descriptor = AgentRuntimeRegistry.descriptor(for: .claudeCode)
        let prerequisite = descriptor.prerequisite
        let executable = resolvedExecutable(
            configuredPath: configuration.claudePath,
            binary: prerequisite.binary
        )

        let cliStatus = await checkExecutable(
            id: "claude-cli",
            title: prerequisite.displayName,
            executable: executable,
            args: prerequisite.livenessArgs,
            missingDetail: "\(prerequisite.displayName) was not found.",
            installHint: prerequisite.installHint
        )
        checks.append(cliStatus.check)

        if cliStatus.isReady, let executable = cliStatus.executable {
            checks.append(await checkClaudeAuth(executable: executable, configuration: configuration))
        }

        switch configuration.claudeProvider {
        case .anthropic:
            checks.append(RuntimeReadinessCheck(
                id: "provider-route",
                title: "Provider route",
                detail: "Anthropic route selected.",
                state: .ready,
                remediation: nil
            ))
        case .vertex:
            checks.append(contentsOf: vertexConfigurationChecks(configuration))
            let gcloud = await checkExecutable(
                id: "gcloud-cli",
                title: "Google Cloud CLI",
                executable: resolvedExecutable(configuredPath: "", binary: "gcloud"),
                args: ["--version"],
                missingDetail: "gcloud was not found on PATH.",
                installHint: CommonCLIPrerequisites.gcloud.installHint
            )
            checks.append(gcloud.check)
            if gcloud.isReady, let executable = gcloud.executable {
                checks.append(await checkVertexADC(gcloudPath: executable))
            }
        }

        return RuntimeReadinessReport(checks: checks)
    }

    private func checkCopilot(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessReport {
        let descriptor = AgentRuntimeRegistry.descriptor(for: .copilotCLI)
        let prerequisite = descriptor.prerequisite
        let executable = resolvedExecutable(
            configuredPath: configuration.copilotPath,
            binary: prerequisite.binary
        )
        let cliStatus = await checkExecutable(
            id: "copilot-cli",
            title: prerequisite.displayName,
            executable: executable,
            args: prerequisite.livenessArgs,
            missingDetail: "\(prerequisite.displayName) was not found.",
            installHint: prerequisite.installHint
        )

        var checks = [cliStatus.check]
        if cliStatus.isReady {
            checks.append(copilotAccountDeferredCheck())
        }
        return RuntimeReadinessReport(checks: checks)
    }

    // MARK: - Individual probes

    private func checkClaudeAuth(
        executable: String,
        configuration: RuntimeReadinessConfiguration
    ) async -> RuntimeReadinessCheck {
        let result = await runner.run(
            path: executable,
            args: ["auth", "status"],
            timeout: timeout,
            environment: claudeProviderEnvironment(for: configuration)
        )

        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "claude-auth",
                title: "Claude authentication",
                detail: "Claude auth status did not pass.",
                state: .blocked,
                remediation: configuration.claudeProvider == .vertex
                    ? "Check Vertex project, region, ADC credentials, and model aliases."
                    : CommonCLIPrerequisites.claude.authHint
            )
        }

        let output = result.stdout.lowercased()
        let compactOutput = output.filter { !$0.isWhitespace }
        if compactOutput.contains("\"loggedin\":true") || output.contains("logged in") || output.contains("authenticated") {
            return RuntimeReadinessCheck(
                id: "claude-auth",
                title: "Claude authentication",
                detail: "Claude reports an authenticated session.",
                state: .ready,
                remediation: nil
            )
        }

        return RuntimeReadinessCheck(
            id: "claude-auth",
            title: "Claude authentication",
            detail: "Claude responded, but no authenticated session was detected.",
            state: .blocked,
            remediation: configuration.claudeProvider == .vertex
                ? "Run `gcloud auth application-default login` and re-check."
                : CommonCLIPrerequisites.claude.authHint
        )
    }

    private func checkVertexADC(gcloudPath: String) async -> RuntimeReadinessCheck {
        let result = await runner.run(
            path: gcloudPath,
            args: ["auth", "application-default", "print-access-token", "--quiet"],
            timeout: timeout,
            environment: nil
        )

        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "vertex-adc",
                title: "Vertex ADC credentials",
                detail: "Application Default Credentials are not available.",
                state: .blocked,
                remediation: "Run `gcloud auth application-default login`."
            )
        }

        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RuntimeReadinessCheck(
                id: "vertex-adc",
                title: "Vertex ADC credentials",
                detail: "ADC command succeeded but returned no token.",
                state: .blocked,
                remediation: "Run `gcloud auth application-default login`."
            )
        }

        return RuntimeReadinessCheck(
            id: "vertex-adc",
            title: "Vertex ADC credentials",
            detail: "Application Default Credentials are available.",
            state: .ready,
            remediation: nil
        )
    }

    private func copilotAccountDeferredCheck() -> RuntimeReadinessCheck {
        let tokenKeys = ["GH_TOKEN", "GITHUB_TOKEN"]
        let hasToken = tokenKeys.contains { key in
            !(ProcessInfo.processInfo.environment[key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        return RuntimeReadinessCheck(
            id: "copilot-account",
            title: "Copilot account",
            detail: hasToken
                ? "CLI is available. GitHub token environment is present; Copilot will validate account access when a task starts."
                : "CLI is available. The Copilot CLI does not expose a safe local auth status check, so account validation happens when a task starts.",
            state: .ready,
            remediation: nil
        )
    }

    private func checkExecutable(
        id: String,
        title: String,
        executable: String?,
        args: [String],
        missingDetail: String,
        installHint: String
    ) async -> ExecutableCheckResult {
        guard let executable, !executable.isEmpty, isExecutable(executable) else {
            return ExecutableCheckResult(
                executable: nil,
                check: RuntimeReadinessCheck(
                    id: id,
                    title: title,
                    detail: missingDetail,
                    state: .blocked,
                    remediation: installHint
                )
            )
        }

        let result = await runner.run(path: executable, args: args, timeout: timeout, environment: nil)
        guard result.isSuccess else {
            return ExecutableCheckResult(
                executable: executable,
                check: RuntimeReadinessCheck(
                    id: id,
                    title: title,
                    detail: processFailureDetail(result),
                    state: .blocked,
                    remediation: "Verify the configured path: \(executable)"
                )
            )
        }

        return ExecutableCheckResult(
            executable: executable,
            check: RuntimeReadinessCheck(
                id: id,
                title: title,
                detail: versionSummary(result.stdout, fallback: "Available at \(executable)"),
                state: .ready,
                remediation: nil
            )
        )
    }

    private func vertexConfigurationChecks(_ configuration: RuntimeReadinessConfiguration) -> [RuntimeReadinessCheck] {
        var checks: [RuntimeReadinessCheck] = []
        let project = trimmed(configuration.vertexProjectID)
        let region = trimmed(configuration.vertexRegion)
        let opus = trimmed(configuration.vertexOpusModel)
        let sonnet = trimmed(configuration.vertexSonnetModel)
        let haiku = trimmed(configuration.vertexHaikuModel)

        checks.append(RuntimeReadinessCheck(
            id: "vertex-project-region",
            title: "Vertex project and region",
            detail: project.isEmpty || region.isEmpty
                ? "Project ID and region are required for Vertex routing."
                : "Using project \(project) in \(region).",
            state: project.isEmpty || region.isEmpty ? .blocked : .ready,
            remediation: project.isEmpty || region.isEmpty ? "Fill GCP Project ID and Region." : nil
        ))

        let missingAliases = [
            ("Opus", opus),
            ("Sonnet", sonnet),
            ("Haiku", haiku)
        ]
        .filter { $0.1.isEmpty }
        .map(\.0)

        checks.append(RuntimeReadinessCheck(
            id: "vertex-model-aliases",
            title: "Vertex model aliases",
            detail: missingAliases.isEmpty
                ? "Opus, Sonnet, and Haiku aliases are configured."
                : "Missing \(missingAliases.joined(separator: ", ")) alias.",
            state: missingAliases.isEmpty ? .ready : .blocked,
            remediation: missingAliases.isEmpty
                ? nil
                : "Fill every Vertex model alias so ASTRA can translate Claude model IDs."
        ))

        return checks
    }

    // MARK: - Helpers

    private struct ExecutableCheckResult {
        let executable: String?
        let check: RuntimeReadinessCheck

        var isReady: Bool { executable != nil && check.state == .ready }
    }

    private func resolvedExecutable(configuredPath: String, binary: String) -> String? {
        let configured = trimmed(configuredPath)
        if !configured.isEmpty { return configured }
        let detected = detectExecutable(binary)
        return detected.isEmpty ? nil : detected
    }

    private func claudeProviderEnvironment(for configuration: RuntimeReadinessConfiguration) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.agentPathSuffix)"
        guard configuration.claudeProvider == .vertex else { return env }

        let project = trimmed(configuration.vertexProjectID)
        let region = trimmed(configuration.vertexRegion)
        if !project.isEmpty {
            env["ANTHROPIC_VERTEX_PROJECT_ID"] = project
        }
        if !region.isEmpty {
            env["CLOUD_ML_REGION"] = region
        }
        env["CLAUDE_CODE_USE_VERTEX"] = "1"

        let opus = trimmed(configuration.vertexOpusModel)
        let sonnet = trimmed(configuration.vertexSonnetModel)
        let haiku = trimmed(configuration.vertexHaikuModel)
        if !opus.isEmpty {
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus
            env["ANTHROPIC_MODEL"] = opus
        }
        if !sonnet.isEmpty {
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet
        }
        if !haiku.isEmpty {
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
            env["ANTHROPIC_SMALL_FAST_MODEL"] = haiku
        }
        return env
    }

    private func processFailureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .launchFailed(let reason):
            return "Could not launch: \(redacted(reason))"
        case .timedOut:
            return "Timed out after \(Int(timeout))s."
        case .exited(let code):
            let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
            let trimmed = redacted(evidence)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Exited with status \(code)."
            }
            return "Exited with status \(code): \(String(trimmed.prefix(140)))"
        }
    }

    private func versionSummary(_ stdout: String, fallback: String) -> String {
        let firstLine = stdout
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return fallback }
        return redacted(firstLine)
    }

    private func redacted(_ value: String) -> String {
        var output = value
        output = output.replacingPattern(
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[redacted-email]",
            options: [.caseInsensitive]
        )
        output = output.replacingPattern(
            #"ya29\.[A-Za-z0-9._-]+"#,
            with: "[redacted-token]"
        )
        output = output.replacingPattern(
            #"sk-[A-Za-z0-9_-]+"#,
            with: "[redacted-key]"
        )
        return output
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultDetectExecutable(_ binary: String) -> String {
        switch binary {
        case "claude":
            return RuntimePathResolver.detectClaudePath()
        case "copilot":
            return RuntimePathResolver.detectCopilotPath()
        default:
            return RuntimePathResolver.detectExecutablePath(named: binary)
        }
    }
}

private extension String {
    func replacingPattern(
        _ pattern: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }
}
