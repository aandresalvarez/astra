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

    /// One line of `agy models`: a launch-ready id (what actually gets
    /// written to settings.json) paired with its human-facing name.
    struct AntigravityModelOption: Equatable, Sendable {
        let id: String
        let displayName: String
    }

    /// A family of `agy` SKUs that differ only by a trailing reasoning-effort
    /// marker (`gemini-3.8-flash-high` / `-medium` / `-low`), discovered by
    /// stripping a marker shared by both the id and its display name.
    /// Antigravity has no separate `--model`/`--effort` pairing at the
    /// settings.json layer `agy` reads from — every SKU `agy models` prints
    /// is already a complete, independently launchable id — so this grouping
    /// exists purely to give the composer's Model/Effort menus the same
    /// two-step shape the other providers have. `fullModelID` always
    /// resolves a (base, effort) choice back to one of the original ids
    /// before it reaches `AgentTask.model`, so that field's meaning never
    /// changes: it is always the exact string `agy` understands.
    struct AntigravityModelGroup: Equatable, Sendable {
        let baseID: String
        let baseDisplayName: String
        /// effort -> full id, e.g. "high" -> "gemini-3.8-flash-high".
        let efforts: [String: String]

        static let displayOrder = ["low", "medium", "high"]

        var sortedEfforts: [String] {
            Self.displayOrder.filter { efforts[$0] != nil }
        }

        /// Effort to preselect when the user switches to this base model
        /// without picking one explicitly — "medium" when offered, else the
        /// next best thing, never silently defaulting to the priciest tier.
        var preferredDefaultEffort: String? {
            for candidate in ["medium", "high", "low"] where efforts[candidate] != nil {
                return candidate
            }
            return sortedEfforts.first
        }
    }

    private static let effortMarkers: [(idSuffix: String, displaySuffix: String, effort: String)] = [
        ("-high", " (High)", "high"),
        ("-medium", " (Medium)", "medium"),
        ("-low", " (Low)", "low"),
    ]

    /// Groups `agy models` options by stripping a trailing effort marker
    /// that both the id and display name agree on. A model with no matching
    /// marker (Claude's ids, which take no `--effort`) becomes its own
    /// single-entry group with no efforts, so its Effort menu stays hidden.
    static func groupModelOptions(_ options: [AntigravityModelOption]) -> [AntigravityModelGroup] {
        var order: [String] = []
        var baseDisplayNames: [String: String] = [:]
        var effortsByBase: [String: [String: String]] = [:]

        for option in options {
            let split = splitEffort(option)
            let baseID = split?.baseID ?? option.id
            let baseDisplayName = split?.baseDisplayName ?? option.displayName
            if baseDisplayNames[baseID] == nil {
                order.append(baseID)
            }
            baseDisplayNames[baseID] = baseDisplayName
            if let effort = split?.effort {
                effortsByBase[baseID, default: [:]][effort] = option.id
            }
        }

        return order.map { baseID in
            AntigravityModelGroup(
                baseID: baseID,
                baseDisplayName: baseDisplayNames[baseID] ?? baseID,
                efforts: effortsByBase[baseID] ?? [:]
            )
        }
    }

    private static func splitEffort(
        _ option: AntigravityModelOption
    ) -> (baseID: String, baseDisplayName: String, effort: String)? {
        for marker in effortMarkers {
            guard option.id.hasSuffix(marker.idSuffix),
                  option.displayName.hasSuffix(marker.displaySuffix) else { continue }
            let baseID = String(option.id.dropLast(marker.idSuffix.count))
            let baseDisplayName = String(option.displayName.dropLast(marker.displaySuffix.count))
            guard !baseID.isEmpty, !baseDisplayName.isEmpty else { continue }
            return (baseID, baseDisplayName, marker.effort)
        }
        return nil
    }

    /// Resolves a (base, effort) choice from the composer back to one of
    /// `agy`'s real model ids. Falls back to `base` unchanged when there is
    /// no matching SKU — including when `base` is already a complete id
    /// (nothing to append to) — which keeps this safe to call on values
    /// persisted before this grouping existed.
    static func fullModelID(base: String, effort: String?, groups: [AntigravityModelGroup]) -> String {
        guard let effort,
              let group = groups.first(where: { $0.baseID == base }),
              let fullID = group.efforts[effort] else {
            return base
        }
        return fullID
    }

    /// Inverse of `fullModelID`: given the id currently stored on the task,
    /// finds which group it belongs to and which effort (if any) it
    /// represents, so the composer can preselect both menus correctly.
    static func currentSelection(
        model: String,
        groups: [AntigravityModelGroup]
    ) -> (baseID: String, effort: String?) {
        for group in groups {
            if group.baseID == model {
                return (group.baseID, nil)
            }
            for (effort, fullID) in group.efforts where fullID == model {
                return (group.baseID, effort)
            }
        }
        return (model, nil)
    }

    static func detectPath() -> String {
        RuntimePathResolver.detectAntigravityPath()
    }

    static func authReadablePaths(userHome: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let trimmedHome = userHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else { return [] }
        // agy's own session decryption key is stored in the macOS login
        // keychain DB (`Antigravity Safe Storage`) and is read via
        // SecItemCopyMatching on every run — including when Autonomous mode
        // drops agy's own `--sandbox` confinement and ASTRA wraps it in
        // Seatbelt instead. Without this grant the strict read-scope profile
        // denies that read and agy reports "authentication failed or timed
        // out" instead of using the stored session. Mirrors
        // ClaudeCodeRuntime.authReadablePaths / CopilotCLIRuntime.
        // authReadablePaths / CursorCLIRuntime.authReadablePaths: only the
        // login keychain DB file is granted, read-only; metadata.keychain-db
        // is deliberately withheld.
        return [
            (trimmedHome as NSString).appendingPathComponent("Library/Keychains/login.keychain-db")
        ]
    }

    /// The ADC route's credentials live outside the keychain, so
    /// `authReadablePaths` alone leaves `AGY_ADC_AUTH=true` pointing at a file
    /// Seatbelt denies: readiness passes (it runs the same grant) and the task
    /// then fails to authenticate. Mirrors
    /// `ClaudeCodeRuntime.vertexADCReadablePaths`, which grants the same
    /// directory for the Vertex route. Empty for consumer sign-in, so the
    /// grant only exists while the route that needs it is selected.
    static func adcReadablePaths(
        mode: AntigravityAuthMode,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        guard mode == .adc else { return [] }
        let trimmedHome = userHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else { return [] }
        let gcloudConfig = ExecutionEnvironmentCredentialProjection.defaultGCPADCHostPath(
            homeDirectory: trimmedHome
        )
        return [
            gcloudConfig,
            (gcloudConfig as NSString).appendingPathComponent(
                ExecutionEnvironmentCredentialProjection.gcpADCFileName
            )
        ]
    }

    /// `defaults:`-based twin of `adcReadablePaths(mode:userHome:)`, for the
    /// launch and utility paths that resolve the route from settings.
    static func adcReadablePaths(
        defaults: UserDefaults = .standard,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        adcReadablePaths(mode: resolvedAuthMode(defaults: defaults), userHome: userHome)
    }

    /// Everything an Antigravity launch has to be able to read. Callers use
    /// this rather than concatenating the two lists themselves, so a launch
    /// site cannot pick up the keychain grant and silently miss the ADC one.
    static func launchReadablePaths(
        defaults: UserDefaults = .standard,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        authReadablePaths(userHome: userHome) + adcReadablePaths(defaults: defaults, userHome: userHome)
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
        modelOptions(executablePath: executablePath)?.map(\.id)
    }

    static func modelOptions(executablePath: String) -> [AntigravityModelOption]? {
        guard FileManager.default.isExecutableFile(atPath: executablePath),
              let output = runProbe(executablePath: executablePath, args: ["models"], timeoutSeconds: 8) else {
            return nil
        }
        let options = parseModelOptions(output)
        return options.isEmpty ? nil : options
    }

    /// Parses `agy models` output into (id, display name) pairs. Real output
    /// is tab-separated (`<id>\t<display name>`, confirmed against the
    /// installed CLI); a bare line with no tab — as in the static
    /// `bundledModelNames` fallback — keeps that string as both id and
    /// display name. `agy` also prints a `Fetching available models...`
    /// progress line to stderr while the table loads, and `runProbe` merges
    /// stdout+stderr, so that line (and the "Available models"/"Tip:"
    /// header lines) must be filtered before it is mistaken for a model.
    static func parseModelOptions(_ output: String) -> [AntigravityModelOption] {
        var seen: Set<String> = []
        var options: [AntigravityModelOption] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            guard !lower.hasPrefix("available models"),
                  !lower.hasPrefix("tip:"),
                  !lower.hasPrefix("fetching") else { continue }
            let columns = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let id = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let displayName = columns.count > 1
                ? columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            options.append(AntigravityModelOption(id: id, displayName: displayName.isEmpty ? id : displayName))
        }
        return options
    }

    /// `[String]` twin of `parseModelOptions`, for callers that only need
    /// the launch-ready ids (e.g. a log line).
    static func parseModelNames(_ output: String) -> [String] {
        RuntimeModelAvailability.cleanProviderModels(parseModelOptions(output).map(\.id))
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

    /// Resolves the Antigravity auth-routing env var from the persisted
    /// setting, so the spawned `agy` process inherits the user's chosen
    /// sign-in method. GUI apps don't pick up shell env from
    /// `.zshrc`/`.zprofile`, so this is the only place the ADC route reaches
    /// the runtime — exporting it in a terminal has no effect on ASTRA's own
    /// launches.
    static func authEnvironment(defaults: UserDefaults = .standard) -> [String: String] {
        authEnvironment(mode: resolvedAuthMode(defaults: defaults))
    }

    /// The persisted route, defaulting to consumer sign-in when unset or
    /// unrecognized.
    static func resolvedAuthMode(defaults: UserDefaults = .standard) -> AntigravityAuthMode {
        let raw = defaults.string(forKey: AppStorageKeys.antigravityAuthMode) ?? AntigravityAuthMode.consumer.rawValue
        return AntigravityAuthMode(rawValue: raw) ?? .consumer
    }

    /// Env keys the selected route needs *absent* from the child process.
    /// `agy` treats the mere presence of `AGY_ADC_AUTH` as "use ADC" — its own
    /// logout text says to `unset` the variable, not set it to false — so
    /// consumer mode cannot express itself as an override. If ASTRA was itself
    /// launched with the variable exported, every env here is built from
    /// `RuntimeProcessEnvironment.enriched`, which starts from
    /// `ProcessInfo.processInfo.environment`; without removal the inherited
    /// value outlives the user switching back to Google Sign-In.
    static func authEnvironmentRemovedKeys(mode: AntigravityAuthMode) -> [String] {
        mode == .adc ? [] : ["AGY_ADC_AUTH"]
    }

    /// Pure variant for call sites that already have the resolved mode
    /// threaded through (e.g. `RuntimeReadinessConfiguration`), so the
    /// live-account readiness check honors the same setting as a real
    /// launch without re-reading `UserDefaults` itself.
    static func authEnvironment(mode: AntigravityAuthMode) -> [String: String] {
        guard mode == .adc else { return [:] }
        return ["AGY_ADC_AUTH": "true"]
    }

    /// `RuntimeProcessEnvironment.enriched` with the route's removals applied.
    /// Antigravity launches go through this instead of `enriched` directly:
    /// `enriched` only ever sets keys, so it cannot express consumer mode.
    static func enrichedEnvironment(
        additionalPaths: [String] = [],
        extraVariables: [String: String],
        mode: AntigravityAuthMode
    ) -> [String: String] {
        var environment = RuntimeProcessEnvironment.enriched(
            additionalPaths: additionalPaths,
            extraVariables: extraVariables
        )
        for key in authEnvironmentRemovedKeys(mode: mode) {
            environment.removeValue(forKey: key)
        }
        return environment
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
        permissionArguments: [String],
        defaults: UserDefaults = .standard
    ) -> AntigravityCLICommandPlan {
        // Plain text gives ASTRA prose and nothing else: no turn boundary, no
        // usage, no session id, and tool calls only as scraped text. The
        // structured stream carries all four, which is what lets an Antigravity
        // run report tokens and end on a real terminal event rather than on
        // process exit alone. Older builds reject the flag and would fail the
        // launch, so this asks first.
        let structuredOutput = structuredOutputSupported(executablePath: executablePath, defaults: defaults)
        var args = ["--print", prompt]
        if structuredOutput {
            args += ["--output-format", "stream-json"]
        }
        args += ["--print-timeout", printTimeoutArgument(timeoutSeconds)]
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
        for (key, value) in authEnvironment(defaults: defaults) {
            extraVars[key] = value
        }
        for (key, value) in taskEnvironment {
            extraVars[key] = value
        }
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            extraVars["HOME"] = trimmedHome
        }
        let additionalPathPrefix = includeAstraToolsPath
            ? pathPrefix + [RuntimePathResolver.astraToolsPath]
            : pathPrefix
        let env = enrichedEnvironment(
            additionalPaths: additionalPathPrefix,
            extraVariables: extraVars,
            mode: resolvedAuthMode(defaults: defaults)
        )

        return AntigravityCLICommandPlan(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            parsesJSONLines: structuredOutput,
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

    /// Whether this `agy` understands `--output-format`. Older builds reject
    /// the flag outright and the run dies on launch, so the answer is probed
    /// from `--help` (50 ms, no auth, no quota) during the readiness check and
    /// cached — `buildCommand` only ever reads the cached verdict, since it
    /// runs on the main actor and must not shell out.
    ///
    /// Unknown means plain text. That costs a run its token accounting until
    /// the first readiness check lands, which is the harmless direction to be
    /// wrong in; assuming support and being wrong fails the run outright.
    static func structuredOutputSupported(
        executablePath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let cached = defaults.string(forKey: AppStorageKeys.runtimeStructuredOutputKey(for: .antigravityCLI)),
              let separator = cached.lastIndex(of: ":") else {
            return false
        }
        let stamp = String(cached[cached.startIndex..<separator])
        let verdict = String(cached[cached.index(after: separator)...])
        guard stamp == executableStamp(executablePath) else { return false }
        return verdict == "true"
    }

    @discardableResult
    static func refreshStructuredOutputSupport(
        executablePath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let stamp = executableStamp(executablePath)
        let key = AppStorageKeys.runtimeStructuredOutputKey(for: .antigravityCLI)
        if let cached = defaults.string(forKey: key),
           let separator = cached.lastIndex(of: ":"),
           String(cached[cached.startIndex..<separator]) == stamp {
            return String(cached[cached.index(after: separator)...]) == "true"
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath),
              let help = runProbe(executablePath: executablePath, args: ["--help"], timeoutSeconds: 8) else {
            return false
        }
        let supported = parseStructuredOutputSupport(help)
        cacheStructuredOutputSupport(supported, executablePath: executablePath, defaults: defaults)
        return supported
    }

    static func cacheStructuredOutputSupport(
        _ supported: Bool,
        executablePath: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            "\(executableStamp(executablePath)):\(supported)",
            forKey: AppStorageKeys.runtimeStructuredOutputKey(for: .antigravityCLI)
        )
    }

    /// `agy --help` prints its flags one per line; the flag's presence is the
    /// whole signal.
    static func parseStructuredOutputSupport(_ helpText: String) -> Bool {
        helpText.contains("--output-format")
    }

    private static func executableStamp(_ executablePath: String) -> String {
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        return "\(trimmed)@\(AgentRuntimeProcessRunner.fileModificationTimestamp(trimmed))"
    }

    /// Structured frames when the run asked for `--output-format stream-json`,
    /// falling back to the plain-text parser for anything agy prints outside
    /// that stream — banners, and the auth/permission notices the plain-text
    /// path still owns.
    static func parseEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        guard parsesJSONLines,
              let events = AntigravityStreamEventParser.parseStructured(line: line) else {
            return parsePlainText(line: line)
        }
        return events
    }

    static func parseAgentEvents(line: String, parsesJSONLines: Bool) -> [AgentEvent] {
        guard parsesJSONLines,
              let events = AntigravityStreamEventParser.parseStructuredAgentEvents(line: line) else {
            return parsePlainTextAgentEvents(line: line, appendingNewline: true)
        }
        return events
    }

    static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        parsePlainTextAgentEvents(line: line, appendingNewline: appendingNewline)
            .compactMap(AgentEventRecorder.parsedEvent(from:))
    }

    static func parsePlainTextAgentEvents(line: String, appendingNewline: Bool = false) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // agy separates paragraphs with blank lines; preserve the boundary
            // in the recorded stream so answers keep their paragraph breaks
            // instead of collapsing into one wall of text.
            return appendingNewline ? [.text(text: "\n")] : []
        }
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
