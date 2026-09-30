import Foundation
import ASTRACore
import os

/// What ASTRA can see of the local Google Cloud Application Default
/// Credentials that the Antigravity ADC route (`AGY_ADC_AUTH=true`) relies on.
///
/// gcloud owns this file; ASTRA only reads it. The quota project shown here is
/// the one `agy` will bill against, so it is read back rather than remembered
/// from what the user last typed into Settings.
enum AntigravityADCStatus: Equatable, Sendable {
    case gcloudMissing
    case notSignedIn
    /// `quotaProject` is nil when the credentials exist but no
    /// `set-quota-project` has been run for them.
    case signedIn(quotaProject: String?)
    case unreadable(String)
}

enum AntigravityADCSetupPhase: Equatable, Sendable {
    case launched(RuntimeAuthLaunchMethod)
    case waitingForSignIn(elapsed: Int)
    case settingQuotaProject
}

enum AntigravityADCSetupOutcome: Equatable, Sendable {
    case configured(quotaProject: String)
    /// Sign-in finished but `set-quota-project` failed; `detail` is the
    /// sanitized gcloud message (usually a permission error on the project).
    case quotaProjectFailed(detail: String)
    case timedOut
    case invalidProject(String)
    case gcloudMissing
    case cancelled
}

/// Drives "sign in with Google Cloud" for the Antigravity ADC route from the
/// Settings page: hands `gcloud auth application-default login` to Terminal
/// (the browser OAuth step is the user's), waits for gcloud to rewrite the
/// ADC file, then runs the non-interactive `set-quota-project` itself.
struct AntigravityADCSetupService: Sendable {
    var homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    var launcher: any TerminalCommandLaunching = TerminalAppLauncher()
    var runner: any BinaryRunner = ProcessBinaryRunner()
    var detectExecutable: @Sendable (String) -> String = {
        RuntimePathResolver.detectExecutablePath(named: $0)
    }
    /// Browser OAuth flows routinely take minutes; matches the runtime sign-in cap.
    var maxDuration: TimeInterval = 300
    var pollInterval: TimeInterval = 3
    var commandTimeout: TimeInterval = 30
    var sleep: @Sendable (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ASTRA",
        category: "antigravity-adc"
    )

    var credentialsURL: URL {
        URL(fileURLWithPath: ExecutionEnvironmentCredentialProjection.defaultGCPADCHostPath(homeDirectory: homeDirectory))
            .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
    }

    // MARK: - Status

    func status() -> AntigravityADCStatus {
        guard !detectExecutable("gcloud").isEmpty else { return .gcloudMissing }
        return credentialStatus()
    }

    /// Reads only `quota_project_id`; the refresh token and client secret in
    /// the same file are never copied out of the parsed dictionary.
    func credentialStatus() -> AntigravityADCStatus {
        let broker = HostFileAccessBroker(homeDirectory: URL(fileURLWithPath: homeDirectory))
        guard broker.fileExists(at: credentialsURL, intent: .explicitUserSelection) else {
            return .notSignedIn
        }
        do {
            let data = try broker.readData(
                at: credentialsURL,
                maxBytes: 64 * 1024,
                keeping: .prefix,
                intent: .explicitUserSelection
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable("The Application Default Credentials file is not a JSON object.")
            }
            let project = (object["quota_project_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .signedIn(quotaProject: project?.isEmpty == false ? project : nil)
        } catch {
            return .unreadable("ASTRA could not read \(credentialsURL.path).")
        }
    }

    // MARK: - Commands

    /// Terminal command for the interactive browser sign-in. `--project`
    /// preselects the quota project gcloud records alongside the credentials.
    static func loginCommand(gcloudPath: String, project: String) -> String {
        [
            RuntimeRemediationCatalog.shellQuoted(gcloudPath),
            "auth", "application-default", "login",
            "--project=" + RuntimeRemediationCatalog.shellQuoted(project)
        ].joined(separator: " ")
    }

    static func displayLoginCommand(project: String) -> String {
        "gcloud auth application-default login --project=\(project)"
    }

    static func quotaProjectArguments(project: String) -> [String] {
        ["auth", "application-default", "set-quota-project", project]
    }

    // MARK: - Setup

    func setUp(
        project rawProject: String,
        onPhase: @escaping @Sendable (AntigravityADCSetupPhase) async -> Void
    ) async -> AntigravityADCSetupOutcome {
        let project = rawProject.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = GCPProjectIDValidation.failure(for: project) {
            return .invalidProject(failure == .empty ? "Enter the Google Cloud project to bill Antigravity against." : failure.message)
        }
        let gcloud = detectExecutable("gcloud")
        guard !gcloud.isEmpty else { return .gcloudMissing }

        let before = modificationDate()
        let command = Self.loginCommand(gcloudPath: gcloud, project: project)
        do {
            try await launcher.launchInTerminal(command: command)
            await onPhase(.launched(.scriptedTerminal))
        } catch {
            let reason = (error as? TerminalLaunchError)?.reason ?? error.localizedDescription
            launcher.openTerminalApp()
            await onPhase(.launched(.manualCopy(reason: reason)))
        }
        Self.log.info("adc setup launched")

        var elapsed: TimeInterval = 0
        var signedIn = false
        while elapsed < maxDuration {
            if Task.isCancelled { return .cancelled }
            do { try await sleep(pollInterval) } catch { return .cancelled }
            elapsed += pollInterval
            await onPhase(.waitingForSignIn(elapsed: Int(elapsed)))
            if let after = modificationDate(), after != before {
                signedIn = true
                break
            }
        }
        guard signedIn else {
            Self.log.info("adc setup timed out")
            return .timedOut
        }

        await onPhase(.settingQuotaProject)
        return await setQuotaProject(project, gcloudPath: gcloud)
    }

    /// Also offered on its own, for a user whose credentials already exist
    /// but point at the wrong project.
    func setQuotaProject(_ rawProject: String, gcloudPath: String? = nil) async -> AntigravityADCSetupOutcome {
        let project = rawProject.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = GCPProjectIDValidation.failure(for: project) {
            return .invalidProject(failure == .empty ? "Enter the Google Cloud project to bill Antigravity against." : failure.message)
        }
        let gcloud = gcloudPath ?? detectExecutable("gcloud")
        guard !gcloud.isEmpty else { return .gcloudMissing }

        let result = await runner.run(
            path: gcloud,
            args: Self.quotaProjectArguments(project: project),
            timeout: commandTimeout,
            environment: nil
        )
        guard result.isSuccess else {
            let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
            let sanitized = RuntimeReadinessRedactor.redacted(evidence)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("adc set-quota-project failed exit=\(result.exitCode ?? -1)")
            return .quotaProjectFailed(detail: sanitized.isEmpty
                ? "gcloud exited with status \(result.exitCode ?? -1)."
                : String(sanitized.prefix(300)))
        }
        Self.log.info("adc set-quota-project succeeded")
        return .configured(quotaProject: project)
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: credentialsURL.path))?[.modificationDate] as? Date
    }
}
