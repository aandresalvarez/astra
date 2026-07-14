import AppKit
import Foundation
import ASTRACore
import os
import ASTRAPersistence
import ASTRAModels

/// Owns every piece of state behind the onboarding wizard's Runtime step
/// (and any future runtime-setup surface): binary probes, per-runtime auth
/// probes, the readiness report for the selected runtime, in-flight
/// installs, and sign-in sessions.
///
/// Invariants the old view-local orchestration could not keep:
///   - one coalesced refresh at a time (Check Again / selection changes /
///     step appearance cancel-and-restart instead of racing),
///   - the last readiness report stays visible while re-checking (no red
///     "One AI runtime required" flash mid-probe),
///   - installs never change the selected runtime before they succeed,
///   - auto-selection never overwrites a choice the user made,
///   - at most one install and one sign-in session app-wide.
@MainActor
final class RuntimeSetupModel: ObservableObject {

    struct InstallState: Equatable {
        let runtime: AgentRuntimeID
        let displayCommand: String?
    }

    struct AuthSessionState: Equatable {
        let runtime: AgentRuntimeID
        var statusText: String
        var commandWasCopied = false
        /// Wall-clock seconds since the poll loop started — surfaced so
        /// the user sees ASTRA is still checking and roughly how long
        /// they have left before the session gives up.
        var elapsedSeconds: Int = 0
        /// One-line "last we saw" — e.g. "Last check: 0 credentials".
        /// Empty until the first probe lands.
        var lastObservation: String = ""
    }

    /// One aggregate state driving the hero card and the footer copy.
    enum SetupStatus: Equatable {
        case checking
        case ready(AgentRuntimeID)
        case readyUnverified(AgentRuntimeID, note: String)
        case needsSignIn(AgentRuntimeID)
        case needsInstall(AgentRuntimeID)
        case blocked(AgentRuntimeID, detail: String)
        case installing(AgentRuntimeID)
        case signingIn(AgentRuntimeID)
    }

    @Published private(set) var statuses: [AgentRuntimeID: HealthStatus] = [:]
    @Published private(set) var authStates: [AgentRuntimeID: RuntimeProviderAuthState] = [:]
    @Published private(set) var probing: Set<AgentRuntimeID> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var readinessReport: RuntimeReadinessReport?
    @Published private(set) var isCheckingReadiness = false
    @Published private(set) var installState: InstallState?
    @Published private(set) var installResult: RuntimeCLIInstallResult?
    @Published private(set) var authSession: AuthSessionState?
    @Published private(set) var githubStatus: HealthStatus?
    @Published private(set) var githubAuthStatus: HealthStatus?
    @Published private(set) var selectedRuntime: AgentRuntimeID
    /// True once the first full refresh has landed — UI seeding (e.g. the
    /// not-installed disclosure default) must wait for real probe data.
    @Published private(set) var hasCompletedInitialRefresh = false

    // MARK: Dependencies (injected for tests)

    var probe: (CLIPrerequisite, _ forceRefresh: Bool) async -> HealthStatus
    var checkReadiness: (RuntimeReadinessConfiguration) async -> RuntimeReadinessReport
    var installer: RuntimeCLIInstaller
    var authRunner: RuntimeAuthSessionRunner
    var copyToPasteboard: (String) -> Void
    private let defaults: UserDefaults
    private let runtimes: [AgentRuntimeID]

    private var refreshTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var userMadeExplicitSelection = false
    private var activationObserver: NSObjectProtocol?
    /// Generation counters so a cancelled-but-still-unwinding task can
    /// never clear the busy flags or overwrite the report of its
    /// replacement (defer blocks run even after cancellation).
    private var refreshGeneration = 0
    private var readinessGeneration = 0
    /// Which runtime the current `readinessReport` was computed for — the
    /// Next gate must not honor a stale report right after a switch, even
    /// though the UI keeps rendering it to avoid a red flash.
    private var readinessReportRuntime: AgentRuntimeID?

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ASTRA",
        category: "runtime-setup"
    )

    init(
        runtimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs,
        defaults: UserDefaults = .standard,
        probe: ((CLIPrerequisite, Bool) async -> HealthStatus)? = nil,
        checkReadiness: ((RuntimeReadinessConfiguration) async -> RuntimeReadinessReport)? = nil,
        installer: RuntimeCLIInstaller = RuntimeCLIInstaller(),
        authRunner: RuntimeAuthSessionRunner = RuntimeAuthSessionRunner(),
        copyToPasteboard: ((String) -> Void)? = nil
    ) {
        self.runtimes = runtimes
        self.defaults = defaults
        self.probe = probe ?? { _, _ in .missingBinary }
        self.checkReadiness = checkReadiness ?? { configuration in
            await RuntimeReadinessService().check(configuration: configuration)
        }
        self.installer = installer
        self.authRunner = authRunner
        self.copyToPasteboard = copyToPasteboard ?? { command in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        self.selectedRuntime = AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: defaults.string(forKey: AppStorageKeys.defaultRuntimeID)
        )
        observeAppActivation()
    }

    /// The wizard injects the shared environment `PreflightCache` once the
    /// view appears (environment values are not available at @StateObject
    /// init time). No-op when a custom probe was injected.
    func attach(preflightCache: PreflightCache) {
        guard !hasAttachedCache else { return }
        hasAttachedCache = true
        probe = { prerequisite, forceRefresh in
            if forceRefresh {
                await preflightCache.invalidate(binary: prerequisite.binary)
            }
            return await preflightCache.status(for: prerequisite)
        }
    }

    private var hasAttachedCache = false

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: - Derived state

    var claudeProvider: ClaudeProvider {
        ClaudeProvider(rawValue: defaults.string(forKey: AppStorageKeys.claudeProvider) ?? "") ?? .anthropic
    }

    var isCoreRuntimeReady: Bool {
        guard let readinessReport, readinessReportRuntime == selectedRuntime else { return false }
        return !readinessReport.checks.contains { $0.state == .blocked }
    }

    var runtimeBlockers: [RuntimeReadinessCheck] {
        guard readinessReportRuntime == selectedRuntime else { return [] }
        return readinessReport?.checks.filter { $0.state == .blocked } ?? []
    }

    var isBusy: Bool {
        isRefreshing || isCheckingReadiness || installState != nil || authSession != nil
    }

    var setupStatus: SetupStatus {
        if let installState { return .installing(installState.runtime) }
        if let authSession { return .signingIn(authSession.runtime) }
        return baseStatus
    }

    /// Like `setupStatus`, but in-flight work on OTHER runtimes does not
    /// hide the selected runtime's blocker — the hero card must keep its
    /// remediation visible while a catalog runtime installs or signs in.
    var heroStatus: SetupStatus {
        if let installState, installState.runtime == selectedRuntime {
            return .installing(installState.runtime)
        }
        if let authSession, authSession.runtime == selectedRuntime {
            return .signingIn(authSession.runtime)
        }
        return baseStatus
    }

    private var baseStatus: SetupStatus {
        if readinessReport == nil {
            if isRefreshing || isCheckingReadiness { return .checking }
        }
        guard let readinessReport else { return .needsInstall(selectedRuntime) }
        guard readinessReportRuntime == selectedRuntime else { return .checking }

        if readinessReport.checks.contains(where: { $0.state == .blocked }) {
            switch statuses[selectedRuntime] {
            case .none, .missingBinary:
                return .needsInstall(selectedRuntime)
            case .healthy, .unauthenticated, .unresponsive:
                break
            }
            if runtimeBlockers.contains(where: Self.isAuthCheck) {
                return .needsSignIn(selectedRuntime)
            }
            let blocker = runtimeBlockers.first
            return .blocked(selectedRuntime, detail: blocker?.remediation ?? blocker?.detail ?? "Resolve the blocked check below.")
        }

        if case .unverified(let note) = authStates[selectedRuntime] {
            return .readyUnverified(selectedRuntime, note: note)
        }
        return .ready(selectedRuntime)
    }

    /// Footer blocker copy — status-specific instead of the old generic
    /// "Finish AI runtime setup before continuing."
    var continueBlockerText: String? {
        guard !isCoreRuntimeReady else { return nil }
        switch setupStatus {
        case .checking, .ready, .readyUnverified:
            return nil
        case .needsSignIn(let runtime):
            return "Sign in to \(runtime.displayName) to continue."
        case .needsInstall:
            return "Install a runtime to continue."
        case .blocked(let runtime, _):
            return "Finish \(runtime.displayName) setup to continue."
        case .installing(let runtime):
            return "Installing \(runtime.displayName)…"
        case .signingIn(let runtime):
            return "Waiting for the \(runtime.displayName) sign-in…"
        }
    }

    var isGitHubReady: Bool {
        guard case .healthy = githubStatus, case .healthy = githubAuthStatus else { return false }
        return true
    }

    func status(for runtime: AgentRuntimeID) -> HealthStatus? {
        statuses[runtime]
    }

    func authState(for runtime: AgentRuntimeID) -> RuntimeProviderAuthState {
        authStates[runtime] ?? .unknown
    }

    func isInstalled(_ runtime: AgentRuntimeID) -> Bool {
        if case .healthy = statuses[runtime] { return true }
        return false
    }

    func remediation(for runtime: AgentRuntimeID) -> RuntimeRemediation {
        RuntimeRemediationCatalog.remediation(for: runtime, claudeProvider: claudeProvider)
    }

    func installPlanDisplayCommand(for runtime: AgentRuntimeID) -> String? {
        installer.plan(for: runtime)?.displayCommand
    }

    // MARK: - Refresh

    /// Coalesced full refresh: binary probes for every runtime, auth
    /// probes for the installed ones, the gh capability pair, and the
    /// readiness report for the selected runtime. Always cancels any
    /// refresh already in flight.
    func refresh(force: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh(force: force)
        }
    }

    func refreshAndWait(force: Bool) async {
        refreshTask?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.performRefresh(force: force)
            return
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(force: Bool) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        // A cancelled task still unwinds through its defers — only the
        // newest refresh may clear the shared busy flags.
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
                hasCompletedInitialRefresh = true
            }
        }

        await probeAllBinaries(force: force, generation: generation)
        guard !Task.isCancelled else { return }

        await probeAuthForInstalledRuntimes()
        guard !Task.isCancelled else { return }
        reconcileSelection()

        await probeGitHub(force: force)
        guard !Task.isCancelled else { return }

        await refreshReadiness()
    }

    private func probeAllBinaries(force: Bool, generation: Int) async {
        probing = Set(runtimes)
        defer {
            if generation == refreshGeneration { probing = [] }
        }

        let probe = self.probe
        let results = await withTaskGroup(
            of: (AgentRuntimeID, HealthStatus).self,
            returning: [AgentRuntimeID: HealthStatus].self
        ) { group in
            for runtime in runtimes {
                let prerequisite = AgentRuntimeAdapterRegistry.descriptor(for: runtime).prerequisite
                group.addTask {
                    (runtime, await probe(prerequisite, force))
                }
            }
            var collected: [AgentRuntimeID: HealthStatus] = [:]
            for await (runtime, status) in group {
                collected[runtime] = status
            }
            return collected
        }
        guard !Task.isCancelled else { return }

        for (runtime, status) in results {
            statuses[runtime] = status
            if case .healthy(let path, _) = status,
               Self.shouldReplaceConfiguredPath(
                   RuntimeProviderSettingsStore.executablePath(for: runtime, defaults: defaults),
                   with: path
               ) {
                RuntimeProviderSettingsStore.setExecutablePath(path, for: runtime, defaults: defaults)
            }
        }
    }

    /// True auth state per installed runtime, so the list stops showing a
    /// signed-out CLI as a green "Installed – v1.2.3". Bounded parallel,
    /// 5s per probe; a probe timeout maps to "unverified", never to
    /// "signed out" (cold-start Node CLIs flap).
    private func probeAuthForInstalledRuntimes() async {
        let provider = claudeProvider
        let candidates = runtimes.filter(isInstalled)
        guard !candidates.isEmpty else { return }

        let runner = authRunner
        let requests = candidates.map { runtime in
            (runtime, RuntimeAuthSessionRequest(
                runtime: runtime,
                executablePath: resolvedExecutablePath(for: runtime),
                remediation: RuntimeRemediationCatalog.remediation(for: runtime, claudeProvider: provider).auth
            ))
        }

        let evaluations = await withTaskGroup(
            of: (AgentRuntimeID, RuntimeAuthProbeEvaluation?).self,
            returning: [(AgentRuntimeID, RuntimeAuthProbeEvaluation?)].self
        ) { group in
            for (runtime, request) in requests {
                switch request.remediation.verification {
                case .probe:
                    group.addTask { (runtime, await runner.verifyOnce(request)) }
                case .deferredToTaskStart, .manualRecheck:
                    group.addTask { (runtime, nil) }
                }
            }
            var collected: [(AgentRuntimeID, RuntimeAuthProbeEvaluation?)] = []
            for await entry in group {
                collected.append(entry)
            }
            return collected
        }
        guard !Task.isCancelled else { return }

        for (runtime, evaluation) in evaluations {
            authStates[runtime] = Self.authState(
                for: evaluation,
                deferredNote: Self.deferredNote(for: runtime, provider: provider)
            )
        }
    }

    private static func deferredNote(for runtime: AgentRuntimeID, provider: ClaudeProvider) -> String {
        switch RuntimeRemediationCatalog.remediation(for: runtime, claudeProvider: provider).auth.verification {
        case .deferredToTaskStart(let note), .manualRecheck(let note):
            return note
        case .probe:
            return "Sign-in could not be verified yet."
        }
    }

    private static func authState(
        for evaluation: RuntimeAuthProbeEvaluation?,
        deferredNote: String
    ) -> RuntimeProviderAuthState {
        switch evaluation {
        case .none:
            return .unverified(note: deferredNote)
        case .authenticated:
            return .authenticated
        case .signedOut:
            return .unauthenticated(detail: "Installed, but signed out")
        case .indeterminate:
            return .unverified(note: "Sign-in could not be verified yet.")
        case .unsupported(let note):
            return .unverified(note: note)
        case .missingBinary:
            return .unknown
        }
    }

    private func probeGitHub(force: Bool) async {
        let cliStatus = await probe(CommonCLIPrerequisites.githubCLI, force)
        guard !Task.isCancelled else { return }
        githubStatus = cliStatus
        guard case .healthy = cliStatus else {
            githubAuthStatus = nil
            return
        }
        let authStatus = await probe(CommonCLIPrerequisites.githubAuth, force)
        guard !Task.isCancelled else { return }
        githubAuthStatus = authStatus
    }

    /// Re-runs the readiness report for the selected runtime, keeping the
    /// previous report on screen until the new one lands.
    func refreshReadiness() async {
        readinessGeneration += 1
        let generation = readinessGeneration
        isCheckingReadiness = true
        defer {
            if generation == readinessGeneration { isCheckingReadiness = false }
        }
        let configuration = makeReadinessConfiguration()
        let report = await checkReadiness(configuration)
        guard generation == readinessGeneration, !Task.isCancelled else { return }
        readinessReport = report
        readinessReportRuntime = configuration.runtime
        foldReadinessIntoAuthState(report, runtime: configuration.runtime)
    }

    /// For manual-recheck providers (Antigravity), the live readiness
    /// check IS the auth verification — fold its result back into the
    /// row's auth state so a successful Verify visibly flips the chip.
    private func foldReadinessIntoAuthState(_ report: RuntimeReadinessReport, runtime: AgentRuntimeID) {
        guard case .manualRecheck = remediation(for: runtime).auth.verification else { return }
        guard let authCheck = report.checks.first(where: Self.isAuthCheck) else { return }
        switch authCheck.state {
        case .ready:
            authStates[runtime] = .authenticated
        case .blocked:
            authStates[runtime] = .unauthenticated(detail: authCheck.detail)
        case .warning:
            break
        }
    }

    private func makeReadinessConfiguration() -> RuntimeReadinessConfiguration {
        var providerSettings = RuntimeProviderSettingsStore.settings(for: runtimes, defaults: defaults)
        let claudePath = defaults.string(forKey: AppStorageKeys.claudePath) ?? ""
        let copilotPath = defaults.string(forKey: AppStorageKeys.copilotPath) ?? ""
        if !claudePath.isEmpty { providerSettings.setExecutablePath(claudePath, for: .claudeCode) }
        if !copilotPath.isEmpty { providerSettings.setExecutablePath(copilotPath, for: .copilotCLI) }
        return RuntimeReadinessConfiguration(
            runtime: selectedRuntime,
            providerSettings: providerSettings,
            claudeProvider: claudeProvider,
            vertexProjectID: defaults.string(forKey: AppStorageKeys.claudeVertexProjectID) ?? "",
            vertexRegion: defaults.string(forKey: AppStorageKeys.claudeVertexRegion) ?? "",
            vertexOpusModel: defaults.string(forKey: AppStorageKeys.claudeVertexOpusModel) ?? "",
            vertexSonnetModel: defaults.string(forKey: AppStorageKeys.claudeVertexSonnetModel) ?? "",
            vertexHaikuModel: defaults.string(forKey: AppStorageKeys.claudeVertexHaikuModel) ?? ""
        )
    }

    // MARK: - Selection

    func select(_ runtime: AgentRuntimeID) {
        guard runtime != selectedRuntime else { return }
        userMadeExplicitSelection = true
        applySelection(runtime)
        installResult = nil
        // Keep the previous report visible (isCheckingReadiness covers the
        // transition) instead of flashing the step red.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshReadiness()
        }
    }

    private func applySelection(_ runtime: AgentRuntimeID) {
        selectedRuntime = runtime
        defaults.set(runtime.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
    }

    /// Auto-select the best runtime only while the user has not chosen:
    /// never overwrite an explicit pick (this session) and never overwrite
    /// a stored choice that still points at an installed runtime.
    private func reconcileSelection() {
        guard !userMadeExplicitSelection else { return }
        let hasStoredChoice = defaults.string(forKey: AppStorageKeys.defaultRuntimeID) != nil
        if hasStoredChoice, isInstalled(selectedRuntime) { return }

        let ranked = runtimes.sorted { lhs, rhs in
            let lhsRank = Self.selectionRank(lhs, installed: isInstalled(lhs), authState: authState(for: lhs))
            let rhsRank = Self.selectionRank(rhs, installed: isInstalled(rhs), authState: authState(for: rhs))
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsRecommended = RuntimeProviderListPresentation.recommendedOrder.firstIndex(of: lhs) ?? Int.max
            let rhsRecommended = RuntimeProviderListPresentation.recommendedOrder.firstIndex(of: rhs) ?? Int.max
            if lhsRecommended != rhsRecommended { return lhsRecommended < rhsRecommended }
            return (runtimes.firstIndex(of: lhs) ?? 0) < (runtimes.firstIndex(of: rhs) ?? 0)
        }
        guard let best = ranked.first, isInstalled(best), best != selectedRuntime else { return }
        applySelection(best)
    }

    private static func selectionRank(
        _ runtime: AgentRuntimeID,
        installed: Bool,
        authState: RuntimeProviderAuthState
    ) -> Int {
        guard installed else { return 3 }
        switch authState {
        case .authenticated: return 0
        case .unverified, .unknown: return 1
        case .unauthenticated: return 2
        }
    }

    // MARK: - Install

    func install(_ runtime: AgentRuntimeID) {
        guard installState == nil else { return }
        installResult = nil
        installState = InstallState(
            runtime: runtime,
            displayCommand: installer.plan(for: runtime)?.displayCommand
        )
        Self.log.info("install started runtime=\(runtime.rawValue, privacy: .public)")

        installTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.installer.install(runtime: runtime)
            await self.finishInstall(runtime: runtime, result: result)
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    private func finishInstall(runtime: AgentRuntimeID, result: RuntimeCLIInstallResult) async {
        if Task.isCancelled {
            // cancelInstall: don't re-probe (a cancelled probe would stamp
            // a bogus status) — just clear the in-flight state.
            installState = nil
            installResult = RuntimeCLIInstallResult(
                runtime: runtime,
                plan: result.plan,
                succeeded: false,
                summary: "\(runtime.displayName) install was cancelled.",
                detail: nil
            )
            return
        }
        let prerequisite = AgentRuntimeAdapterRegistry.descriptor(for: runtime).prerequisite
        let probed = await probe(prerequisite, true)
        if !Task.isCancelled {
            statuses[runtime] = probed
        }
        installState = nil
        Self.log.info("install finished runtime=\(runtime.rawValue, privacy: .public) succeeded=\(result.succeeded)")

        if result.succeeded, isInstalled(runtime) {
            installResult = RuntimeCLIInstallResult(
                runtime: runtime,
                plan: result.plan,
                succeeded: true,
                summary: "\(runtime.displayName) is installed.",
                detail: nil
            )
            // Selection changes only after a verified install — and only
            // when the user has nothing selected that works.
            if !userMadeExplicitSelection, !isInstalled(selectedRuntime) {
                applySelection(runtime)
            }
            await probeAuthForInstalledRuntimes()
            await refreshReadiness()
        } else if result.succeeded {
            installResult = RuntimeCLIInstallResult(
                runtime: runtime,
                plan: result.plan,
                succeeded: false,
                summary: "\(runtime.displayName) install finished, but ASTRA could not find it yet.",
                detail: "Restart ASTRA or configure the runtime path in Settings, then check again."
            )
        } else {
            installResult = result
        }
    }

    // MARK: - Sign-in

    func signIn(_ runtime: AgentRuntimeID) {
        guard authSession == nil else { return }
        let remediation = remediation(for: runtime).auth
        authSession = AuthSessionState(
            runtime: runtime,
            statusText: "Opening Terminal…"
        )

        let request = RuntimeAuthSessionRequest(
            runtime: runtime,
            executablePath: resolvedExecutablePath(for: runtime),
            remediation: remediation
        )
        let runner = authRunner
        authTask = Task { [weak self] in
            let outcome = await runner.run(request) { [weak self] phase in
                await self?.handleAuthPhase(phase, command: remediation.terminalCommand)
            }
            await self?.finishAuthSession(runtime: runtime, outcome: outcome)
        }
    }

    func cancelSignIn() {
        authTask?.cancel()
    }

    /// Single-shot re-verification — the "Check Now" button, and fired
    /// automatically when the app becomes active while a session waits
    /// (the user tabbing back from Terminal is exactly when to re-check).
    func checkAuthNow() {
        guard let session = authSession else { return }
        let runtime = session.runtime
        let request = RuntimeAuthSessionRequest(
            runtime: runtime,
            executablePath: resolvedExecutablePath(for: runtime),
            remediation: remediation(for: runtime).auth
        )
        let runner = authRunner
        Task { [weak self] in
            if await runner.verifyOnce(request) == .authenticated {
                // Apply the confirmed result directly: it is authoritative
                // even when the poll loop already closed the session with a
                // different outcome in the meantime.
                await self?.applyVerifiedAuth(runtime: runtime)
            }
        }
    }

    private func applyVerifiedAuth(runtime: AgentRuntimeID) async {
        authTask?.cancel()
        if authSession?.runtime == runtime {
            authSession = nil
        }
        authStates[runtime] = .authenticated
        let probed = await probe(AgentRuntimeAdapterRegistry.descriptor(for: runtime).prerequisite, true)
        if !Task.isCancelled {
            statuses[runtime] = probed
        }
        if runtime == selectedRuntime {
            await refreshReadiness()
        }
    }

    private func handleAuthPhase(_ phase: RuntimeAuthSessionPhase, command: String) {
        switch phase {
        case .launched(.scriptedTerminal):
            authSession?.statusText = "Finish signing in in Terminal. ASTRA re-checks every 5s."
        case .launched(.manualCopy):
            copyToPasteboard(command)
            authSession?.commandWasCopied = true
            authSession?.statusText = "Command copied — paste it into Terminal to sign in."
        case .waitingForSignIn:
            break
        case .polled(let elapsed, let observation):
            authSession?.elapsedSeconds = elapsed
            authSession?.lastObservation = observation
        }
    }

    private func finishAuthSession(runtime: AgentRuntimeID, outcome: RuntimeAuthSessionOutcome) async {
        guard authSession?.runtime == runtime else { return }
        authSession = nil

        switch outcome {
        case .verified:
            authStates[runtime] = .authenticated
            statuses[runtime] = await probe(
                AgentRuntimeAdapterRegistry.descriptor(for: runtime).prerequisite,
                true
            )
            if runtime == selectedRuntime {
                await refreshReadiness()
            }
        case .deferred(let note), .manual(let note), .probeUnsupported(let note):
            authStates[runtime] = .unverified(note: note)
            if runtime == selectedRuntime {
                await refreshReadiness()
            }
        case .timedOut:
            authStates[runtime] = .unauthenticated(
                detail: "Still signed out — finish in Terminal, then use Check Again."
            )
        case .failed(let detail):
            authStates[runtime] = .unauthenticated(detail: detail)
        case .cancelled:
            break
        }
    }

    // MARK: - Helpers

    private func resolvedExecutablePath(for runtime: AgentRuntimeID) -> String {
        if case .healthy(let path, _) = statuses[runtime], !path.isEmpty {
            return path
        }
        let configured = RuntimeProviderSettingsStore.executablePath(for: runtime, defaults: defaults)
        if !configured.isEmpty { return configured }
        return RuntimePathResolver.detectExecutablePath(
            named: AgentRuntimeAdapterRegistry.descriptor(for: runtime).executableName
        )
    }

    private static func shouldReplaceConfiguredPath(_ configuredPath: String, with detectedPath: String) -> Bool {
        let configured = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return configured.isEmpty || !FileManager.default.isExecutableFile(atPath: configured)
    }

    private func observeAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAuthNow()
            }
        }
    }

    private static func isAuthCheck(_ check: RuntimeReadinessCheck) -> Bool {
        let id = check.id.lowercased()
        return id.contains("auth") || id.contains("account") || id.contains("adc") || id.contains("login")
    }
}
