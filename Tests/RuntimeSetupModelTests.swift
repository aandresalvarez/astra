import Testing
import Foundation
import ASTRAPersistence
import ASTRAModels
@testable import ASTRA
import ASTRACore

// MARK: - Fixtures

private let testRuntimes: [AgentRuntimeID] = [.claudeCode, .copilotCLI, .codexCLI]

private func makeDefaults() -> UserDefaults {
    let suite = "runtime-setup-model-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private final class CopiedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }
    func append(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        _commands.append(command)
    }
}

private final class NoAutomationLauncher: TerminalCommandLaunching, @unchecked Sendable {
    func launchInTerminal(command _: String) throws {
        throw TerminalLaunchError(reason: "Not authorized")
    }
    func openTerminalApp() {}
}

private final class SilentLauncher: TerminalCommandLaunching, @unchecked Sendable {
    func launchInTerminal(command _: String) throws {}
    func openTerminalApp() {}
}

private let readyReport = RuntimeReadinessReport(checks: [
    RuntimeReadinessCheck(id: "claude-cli", title: "Claude Code CLI", detail: "ok", state: .ready, remediation: nil)
])

private let authBlockedReport = RuntimeReadinessReport(checks: [
    RuntimeReadinessCheck(id: "claude-cli", title: "Claude Code CLI", detail: "ok", state: .ready, remediation: nil),
    RuntimeReadinessCheck(id: "claude-auth", title: "Claude authentication", detail: "signed out", state: .blocked, remediation: "Run `claude /login`.")
])

@MainActor
private func makeModel(
    defaults: UserDefaults = makeDefaults(),
    statuses: [String: HealthStatus],
    authProbeResponses: [String: RunResult] = [:],
    report: RuntimeReadinessReport = readyReport,
    launcher: any TerminalCommandLaunching = SilentLauncher(),
    copied: CopiedCommands = CopiedCommands()
) async -> RuntimeSetupModel {
    let probeStub = StubBinaryRunner()
    for (key, result) in authProbeResponses {
        await probeStub.setResponse(forKey: key, result: result)
    }
    var authRunner = RuntimeAuthSessionRunner()
    authRunner.launcher = launcher
    authRunner.probeRunner = probeStub
    authRunner.detectExecutable = { _ in "" }
    authRunner.pollInterval = 1
    authRunner.requiredConsecutiveSuccesses = 1
    authRunner.maxDuration = 3
    authRunner.sleep = { _ in }

    return RuntimeSetupModel(
        runtimes: testRuntimes,
        defaults: defaults,
        probe: { prerequisite, _ in statuses[prerequisite.id] ?? statuses[prerequisite.binary] ?? .missingBinary },
        checkReadiness: { _ in report },
        installer: RuntimeCLIInstaller(runner: StubBinaryRunner(), detectExecutable: { _ in "" }),
        authRunner: authRunner,
        copyToPasteboard: { copied.append($0) }
    )
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    maxIterations: Int = 2_000
) async {
    var iterations = 0
    while !condition() && iterations < maxIterations {
        iterations += 1
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

// MARK: - Tests

@MainActor
@Suite("Runtime Setup Model")
struct RuntimeSetupModelTests {

    @Test("Refresh probes every runtime and keeps machine-readable auth state per row")
    func refreshProbesBinariesAndAuth() async {
        let model = await makeModel(
            statuses: [
                "claude": .healthy(path: "/bin/claude", version: "2.0"),
                "copilot": .healthy(path: "/bin/copilot", version: "1.0"),
                "codex": .healthy(path: "/bin/codex", version: "0.1")
            ],
            authProbeResponses: [
                "/bin/claude auth status": .exited(code: 0, stdout: "Logged in as user", stderr: ""),
                "/bin/codex login status": .exited(code: 1, stdout: "Not logged in", stderr: "")
            ]
        )

        await model.refreshAndWait(force: false)

        #expect(model.isInstalled(.claudeCode))
        #expect(model.authState(for: .claudeCode) == .authenticated)
        #expect(model.authState(for: .codexCLI) == .unauthenticated(detail: "Installed, but signed out"))
        if case .unverified = model.authState(for: .copilotCLI) {} else {
            Issue.record("Copilot has no probe and must read as unverified, got \(model.authState(for: .copilotCLI))")
        }
        #expect(model.readinessReport != nil)
    }

    @Test("Auto-select prefers an authenticated runtime when nothing was chosen")
    func autoSelectPrefersAuthenticatedRuntime() async {
        let defaults = makeDefaults()
        let model = await makeModel(
            defaults: defaults,
            statuses: [
                "claude": .missingBinary,
                "copilot": .missingBinary,
                "codex": .healthy(path: "/bin/codex", version: "0.1")
            ],
            authProbeResponses: [
                "/bin/codex login status": .exited(code: 0, stdout: "Logged in", stderr: "")
            ]
        )

        await model.refreshAndWait(force: false)

        #expect(model.selectedRuntime == .codexCLI)
        #expect(defaults.string(forKey: AppStorageKeys.defaultRuntimeID) == AgentRuntimeID.codexCLI.rawValue)
    }

    @Test("Auto-select never overwrites an explicit user choice")
    func autoSelectNeverOverwritesExplicitChoice() async {
        let model = await makeModel(
            statuses: [
                "claude": .healthy(path: "/bin/claude", version: "2.0"),
                "copilot": .missingBinary,
                "codex": .missingBinary
            ]
        )

        model.select(.codexCLI)
        await waitUntil { !model.isCheckingReadiness }
        await model.refreshAndWait(force: false)

        #expect(model.selectedRuntime == .codexCLI, "explicit selection must survive probes finding a better runtime")
    }

    @Test("A stored choice that is still installed is left alone")
    func storedInstalledChoiceIsRespected() async {
        let defaults = makeDefaults()
        defaults.set(AgentRuntimeID.copilotCLI.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        let model = await makeModel(
            defaults: defaults,
            statuses: [
                "claude": .healthy(path: "/bin/claude", version: "2.0"),
                "copilot": .healthy(path: "/bin/copilot", version: "1.0"),
                "codex": .missingBinary
            ],
            authProbeResponses: [
                "/bin/claude auth status": .exited(code: 0, stdout: "Logged in", stderr: "")
            ]
        )

        await model.refreshAndWait(force: false)

        #expect(model.selectedRuntime == .copilotCLI)
    }

    @Test("Selecting a runtime keeps the previous readiness report visible")
    func selectionKeepsPreviousReport() async {
        let model = await makeModel(
            statuses: ["claude": .healthy(path: "/bin/claude", version: "2.0")]
        )
        await model.refreshAndWait(force: false)
        #expect(model.readinessReport != nil)

        model.select(.codexCLI)

        #expect(model.readinessReport != nil, "selection must not nil the report into a red flash")
        await waitUntil { !model.isCheckingReadiness }
    }

    @Test("A failed install never hijacks the selected runtime")
    func failedInstallDoesNotChangeSelection() async {
        let defaults = makeDefaults()
        defaults.set(AgentRuntimeID.claudeCode.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        let model = await makeModel(
            defaults: defaults,
            statuses: ["claude": .healthy(path: "/bin/claude", version: "2.0")]
        )
        await model.refreshAndWait(force: false)

        model.install(.codexCLI)
        await waitUntil { model.installState == nil && model.installResult != nil }

        #expect(model.selectedRuntime == .claudeCode)
        #expect(model.installResult?.succeeded == false)
        #expect(defaults.string(forKey: AppStorageKeys.defaultRuntimeID) == AgentRuntimeID.claudeCode.rawValue)
    }

    @Test("Status aggregates to needs-sign-in when the blocker is an auth check")
    func statusMapsAuthBlockerToNeedsSignIn() async {
        let model = await makeModel(
            statuses: ["claude": .healthy(path: "/bin/claude", version: "2.0")],
            report: authBlockedReport
        )
        await model.refreshAndWait(force: false)

        #expect(model.setupStatus == .needsSignIn(.claudeCode))
        #expect(model.continueBlockerText == "Sign in to Claude Code to continue.")
        #expect(!model.isCoreRuntimeReady)
    }

    @Test("Status aggregates to needs-install when the selected runtime is missing")
    func statusMapsMissingRuntimeToNeedsInstall() async {
        let report = RuntimeReadinessReport(checks: [
            RuntimeReadinessCheck(id: "claude-cli", title: "Claude Code CLI", detail: "missing", state: .blocked, remediation: "Install it.")
        ])
        let model = await makeModel(
            statuses: ["claude": .missingBinary, "copilot": .missingBinary, "codex": .missingBinary],
            report: report
        )
        await model.refreshAndWait(force: false)

        #expect(model.setupStatus == .needsInstall(model.selectedRuntime))
        #expect(model.continueBlockerText == "Install a runtime to continue.")
    }

    @Test("A clean report with an unverified provider reads as ready-unverified")
    func statusMapsUnverifiedProviderHonestly() async {
        let defaults = makeDefaults()
        defaults.set(AgentRuntimeID.copilotCLI.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        let model = await makeModel(
            defaults: defaults,
            statuses: ["copilot": .healthy(path: "/bin/copilot", version: "1.0")]
        )
        await model.refreshAndWait(force: false)

        guard case .readyUnverified(let runtime, _) = model.setupStatus else {
            Issue.record("Expected readyUnverified, got \(model.setupStatus)")
            return
        }
        #expect(runtime == .copilotCLI)
        #expect(model.isCoreRuntimeReady, "unverified must not block the wizard gate")
    }

    @Test("An unresponsive selected runtime is blocked, never offered an install")
    func unresponsiveSelectedRuntimeIsNotNeedsInstall() async {
        let defaults = makeDefaults()
        defaults.set(AgentRuntimeID.claudeCode.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        let report = RuntimeReadinessReport(checks: [
            RuntimeReadinessCheck(id: "claude-cli", title: "Claude Code CLI", detail: "exit 1: broken", state: .blocked, remediation: "Verify the configured path.")
        ])
        let model = await makeModel(
            defaults: defaults,
            statuses: ["claude": .unresponsive(detail: "exit 1: broken")],
            report: report
        )
        await model.refreshAndWait(force: false)

        guard case .blocked = model.setupStatus else {
            Issue.record("Expected blocked for an unresponsive binary, got \(model.setupStatus)")
            return
        }
    }

    @Test("Switching runtimes closes the Next gate until a report for the new runtime lands")
    func staleReportDoesNotOpenGateAfterSwitch() async {
        let model = await makeModel(
            statuses: ["claude": .healthy(path: "/bin/claude", version: "2.0")]
        )
        await model.refreshAndWait(force: false)
        #expect(model.isCoreRuntimeReady)

        model.select(.codexCLI)

        #expect(!model.isCoreRuntimeReady, "a report computed for the old runtime must not open the gate")
        #expect(model.readinessReport != nil, "the stale report stays visible to avoid a red flash")
        await waitUntil { model.isCoreRuntimeReady }
        #expect(model.isCoreRuntimeReady, "the gate reopens once the new runtime's report lands")
    }

    @Test("In-flight work on another runtime does not hide the hero's remediation")
    func heroStatusIgnoresOtherRuntimesWork() async {
        let model = await makeModel(
            statuses: [
                "claude": .missingBinary,
                "copilot": .missingBinary,
                "codex": .missingBinary
            ],
            report: RuntimeReadinessReport(checks: [
                RuntimeReadinessCheck(id: "claude-cli", title: "Claude Code CLI", detail: "missing", state: .blocked, remediation: "Install it.")
            ])
        )
        await model.refreshAndWait(force: false)

        model.install(.codexCLI)

        if case .installing = model.heroStatus {
            Issue.record("heroStatus must keep the selected runtime's blocker while another runtime installs")
        }
        guard case .installing = model.setupStatus else {
            await waitUntil { model.installState == nil }
            return
        }
        await waitUntil { model.installState == nil }
    }

    @Test("A verified sign-in session updates the runtime's auth state")
    func signInVerifiedUpdatesAuthState() async {
        let model = await makeModel(
            statuses: ["codex": .healthy(path: "/bin/codex", version: "0.1")],
            authProbeResponses: [
                "/bin/codex login status": .exited(code: 0, stdout: "Logged in", stderr: "")
            ]
        )
        await model.refreshAndWait(force: false)

        model.signIn(.codexCLI)
        await waitUntil { model.authSession == nil }

        #expect(model.authState(for: .codexCLI) == .authenticated)
    }

    @Test("Denied Terminal automation copies the command to the pasteboard")
    func deniedAutomationCopiesCommand() async {
        let copied = CopiedCommands()
        let model = await makeModel(
            statuses: ["codex": .healthy(path: "/bin/codex", version: "0.1")],
            authProbeResponses: [
                "/bin/codex login status": .exited(code: 0, stdout: "Logged in", stderr: "")
            ],
            launcher: NoAutomationLauncher(),
            copied: copied
        )
        await model.refreshAndWait(force: false)

        model.signIn(.codexCLI)
        await waitUntil { model.authSession == nil }

        #expect(copied.commands == ["codex login"])
    }
}
