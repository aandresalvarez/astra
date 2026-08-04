import AppKit
import Combine
import Foundation
import os

enum GitHubRepositoryAccessRepairStage: Equatable, Sendable {
    case currentCredential
    case refreshedCredential
}

enum GitHubRepositoryAccessRepairState: Equatable, Sendable {
    case idle
    case checking
    case awaitingAuthorization(
        stage: GitHubRepositoryAccessRepairStage,
        account: String?,
        repository: String
    )
    case authorizationStillRequired(
        stage: GitHubRepositoryAccessRepairStage,
        account: String?,
        repository: String
    )
    case refreshingCredential(account: String?, repository: String)
    case awaitingDeviceAuthorization(
        account: String?,
        repository: String,
        code: String
    )
    case ready(account: String?, repository: String)
    case blocked(account: String?, repository: String, detail: String)
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .checking, .awaitingAuthorization, .authorizationStillRequired,
             .refreshingCredential, .awaitingDeviceAuthorization:
            true
        case .idle, .ready, .blocked, .failed:
            false
        }
    }

    var isActivelyWorking: Bool {
        switch self {
        case .checking, .refreshingCredential:
            true
        case .idle, .awaitingAuthorization, .authorizationStillRequired,
             .awaitingDeviceAuthorization, .ready, .blocked, .failed:
            false
        }
    }

    var isAwaitingAuthorization: Bool {
        switch self {
        case .awaitingAuthorization, .authorizationStillRequired:
            true
        default:
            false
        }
    }

    var deviceCode: String? {
        guard case .awaitingDeviceAuthorization(_, _, let code) = self else {
            return nil
        }
        return code
    }

    var summary: String? {
        switch self {
        case .idle:
            return nil
        case .checking:
            return "Checking repository access…"
        case .awaitingAuthorization(let stage, let account, _):
            let principal = account.map { " for \($0)" } ?? ""
            switch stage {
            case .currentCredential:
                return "Finish organization SSO\(principal) in GitHub, then return to ASTRA."
            case .refreshedCredential:
                return "Authorize the refreshed GitHub CLI credential\(principal), then return to ASTRA."
            }
        case .authorizationStillRequired(let stage, _, _):
            switch stage {
            case .currentCredential:
                return "GitHub still requires SSO. Continue repair to refresh the GitHub CLI credential."
            case .refreshedCredential:
                return "GitHub still rejects the refreshed credential. Verify final access to diagnose organization policy."
            }
        case .refreshingCredential:
            return "Starting GitHub device authorization…"
        case .awaitingDeviceAuthorization(_, _, let code):
            return "Enter \(code) on the GitHub device page. The code is also copied."
        case .ready(let account, let repository):
            return account.map { "Ready as \($0) for \(repository)" } ?? "Ready for \(repository)"
        case .blocked(_, _, let detail), .failed(let detail):
            return detail
        }
    }
}

@MainActor
final class GitHubRepositoryAccessRepairCoordinator: ObservableObject {
    typealias Probe = @Sendable (
        _ ghPath: String,
        _ workingDirectory: String
    ) async -> GitHubRepositoryAccessStatus
    typealias RefreshCredential = @Sendable (
        _ ghPath: String,
        _ onDeviceCode: @escaping GitHubDeviceCodeHandler
    ) async -> GitHubCLIAuthenticationRefreshOutcome

    @Published private(set) var state: GitHubRepositoryAccessRepairState = .idle

    static let ssoSettingsURL = URL(string: "https://github.com/settings/sso")!

    private let probe: Probe
    private let refreshCredential: RefreshCredential
    private let urlLauncher: any GitHubAuthorizationURLLaunching
    private let detectExecutable: @Sendable (String) -> String
    private let isApplicationActive: @MainActor @Sendable () -> Bool
    private var context: (ghPath: String, workingDirectory: String)?
    private var operationTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var observedExternalTransition = false
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ASTRA",
        category: "github-access-repair"
    )

    init(
        probe: Probe? = nil,
        refreshCredential: RefreshCredential? = nil,
        urlLauncher: any GitHubAuthorizationURLLaunching = SystemGitHubAuthorizationURLLauncher(),
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimePathResolver.detectExecutablePath(named: $0)
        },
        isApplicationActive: @escaping @MainActor @Sendable () -> Bool = {
            NSApplication.shared.isActive
        },
        observesApplicationLifecycle: Bool = true
    ) {
        let accessProbe = GitHubRepositoryAccessProbe()
        let authRefresher = GitHubCLIAuthenticationRefresher()
        self.probe = probe ?? { ghPath, workingDirectory in
            await accessProbe.check(ghPath: ghPath, workingDirectory: workingDirectory)
        }
        self.refreshCredential = refreshCredential ?? { ghPath, onDeviceCode in
            await authRefresher.refresh(
                ghPath: ghPath,
                onDeviceCode: onDeviceCode
            )
        }
        self.urlLauncher = urlLauncher
        self.detectExecutable = detectExecutable
        self.isApplicationActive = isApplicationActive
        if observesApplicationLifecycle {
            observeApplicationLifecycle()
        }
    }

    deinit {
        operationTask?.cancel()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    var actionTitle: String {
        switch state {
        case .awaitingAuthorization:
            return "Verify access"
        case .authorizationStillRequired(let stage, _, _):
            return stage == .currentCredential ? "Continue repair" : "Verify final access"
        case .blocked, .failed:
            return "Retry repair"
        default:
            return "Repair access"
        }
    }

    func start(workingDirectory: String) {
        guard !state.isInProgress, operationTask == nil else { return }
        let normalizedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDirectory.isEmpty else {
            state = .failed("ASTRA cannot repair GitHub access without a workspace repository.")
            return
        }
        let ghPath = detectExecutable("gh")
        guard !ghPath.isEmpty else {
            state = .failed("GitHub CLI is not installed or executable on this Mac.")
            return
        }

        observedExternalTransition = false
        context = (ghPath, normalizedDirectory)
        state = .checking
        launchOperation { [weak self] in
            await self?.inspectInitialStatus()
        }
    }

    func verifyNow() {
        guard operationTask == nil else { return }
        let stage: GitHubRepositoryAccessRepairStage
        switch state {
        case .awaitingAuthorization(let pendingStage, _, _),
             .authorizationStillRequired(let pendingStage, _, _):
            stage = pendingStage
        default:
            return
        }
        observedExternalTransition = false
        state = .checking
        launchOperation { [weak self] in
            await self?.continueAfterAuthorization(
                stage: stage,
                allowRepairAdvancement: true
            )
        }
    }

    func applicationDidResignActive() {
        guard case .awaitingAuthorization = state else { return }
        observedExternalTransition = true
    }

    func applicationDidBecomeActive() {
        guard operationTask == nil,
              observedExternalTransition,
              case .awaitingAuthorization(let stage, _, _) = state else {
            return
        }
        observedExternalTransition = false
        state = .checking
        launchOperation { [weak self] in
            await self?.continueAfterAuthorization(
                stage: stage,
                allowRepairAdvancement: false
            )
        }
    }

    func cancel() {
        operationGeneration += 1
        operationTask?.cancel()
        operationTask = nil
        context = nil
        observedExternalTransition = false
        state = .idle
    }

    func reset() {
        guard !state.isInProgress else { return }
        context = nil
        observedExternalTransition = false
        state = .idle
    }

    func waitForCurrentOperation() async {
        await operationTask?.value
    }

    private func observeApplicationLifecycle() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applicationDidResignActive()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applicationDidBecomeActive()
            }
        }
    }

    private func launchOperation(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        guard operationTask == nil else { return }
        operationGeneration += 1
        let generation = operationGeneration
        operationTask = Task { [weak self] in
            await operation()
            guard let self, self.operationGeneration == generation else { return }
            self.operationTask = nil
        }
    }

    private func inspectInitialStatus() async {
        guard let context else { return }
        let status = await probe(context.ghPath, context.workingDirectory)
        guard !Task.isCancelled else { return }
        switch status {
        case .ready(let account, let repository):
            finishReady(account: account, repository: repository)
        case .samlAuthorizationRequired(
            let account,
            let repository,
            _,
            let authorizationURL
        ):
            if let authorizationURL {
                openAuthorization(
                    authorizationURL,
                    stage: .currentCredential,
                    account: account,
                    repository: repository
                )
            } else {
                await refreshAndReprobe(account: account, repository: repository)
            }
        default:
            finishNonSAML(status)
        }
    }

    private func continueAfterAuthorization(
        stage: GitHubRepositoryAccessRepairStage,
        allowRepairAdvancement: Bool
    ) async {
        guard let context else { return }
        let status = await probe(context.ghPath, context.workingDirectory)
        guard !Task.isCancelled else { return }

        switch status {
        case .ready(let account, let repository):
            finishReady(account: account, repository: repository)
        case .samlAuthorizationRequired(
            let account,
            let repository,
            let organization,
            _
        ):
            guard allowRepairAdvancement else {
                state = .authorizationStillRequired(
                    stage: stage,
                    account: account,
                    repository: repository
                )
                return
            }
            switch stage {
            case .currentCredential:
                await refreshAndReprobe(account: account, repository: repository)
            case .refreshedCredential:
                finishPolicyBlock(
                    account: account,
                    repository: repository,
                    organization: organization
                )
            }
        default:
            finishNonSAML(status)
        }
    }

    private func refreshAndReprobe(account: String?, repository: String) async {
        guard let context else { return }
        state = .refreshingCredential(account: account, repository: repository)
        Self.log.info("github access repair refreshing credential")
        let outcome = await refreshCredential(context.ghPath) { [weak self] code in
            guard let self, self.context != nil else { return }
            self.state = .awaitingDeviceAuthorization(
                account: account,
                repository: repository,
                code: code
            )
        }
        guard !Task.isCancelled else { return }

        state = .checking
        let status = await probe(context.ghPath, context.workingDirectory)
        guard !Task.isCancelled else { return }
        if case .ready(let readyAccount, let readyRepository) = status {
            finishReady(account: readyAccount, repository: readyRepository)
            return
        }

        guard outcome == .refreshed else {
            let detail = outcome.failureDetail ?? "GitHub CLI authorization could not be refreshed."
            state = .failed("\(detail) Repository access is still blocked.")
            Self.log.error("github access repair refresh failed")
            return
        }

        switch status {
        case .samlAuthorizationRequired(
            let refreshedAccount,
            let refreshedRepository,
            let organization,
            let authorizationURL
        ):
            guard let authorizationURL else {
                finishPolicyBlock(
                    account: refreshedAccount,
                    repository: refreshedRepository,
                    organization: organization
                )
                return
            }
            openAuthorization(
                authorizationURL,
                stage: .refreshedCredential,
                account: refreshedAccount,
                repository: refreshedRepository
            )
        default:
            finishNonSAML(status)
        }
    }

    private func openAuthorization(
        _ url: URL,
        stage: GitHubRepositoryAccessRepairStage,
        account: String?,
        repository: String
    ) {
        state = .awaitingAuthorization(
            stage: stage,
            account: account,
            repository: repository
        )
        observedExternalTransition = !isApplicationActive()
        guard urlLauncher.open(url) else {
            observedExternalTransition = false
            state = .failed("ASTRA could not open GitHub's organization authorization page.")
            return
        }
        Self.log.info("github access repair awaiting organization authorization")
    }

    private func finishReady(account: String?, repository: String) {
        state = .ready(account: account, repository: repository)
        context = nil
        observedExternalTransition = false
        Self.log.info("github access repair verified repository")
    }

    private func finishPolicyBlock(
        account: String?,
        repository: String,
        organization: String?
    ) {
        let principal = account.map { " for GitHub account \($0)" } ?? ""
        let owner = organization ?? repository.split(separator: "/").first.map(String.init) ?? "the organization"
        state = .blocked(
            account: account,
            repository: repository,
            detail: "GitHub refreshed the credential\(principal), but \(owner) still did not authorize access to \(repository). Confirm this account is linked in GitHub SSO settings or ask an organization owner to approve GitHub CLI."
        )
        context = nil
        observedExternalTransition = false
        Self.log.warning("github access repair blocked by external organization policy")
    }

    private func finishNonSAML(_ status: GitHubRepositoryAccessStatus) {
        switch status {
        case .ready(let account, let repository):
            finishReady(account: account, repository: repository)
        case .noWorkspaceRepository:
            state = .failed("ASTRA could not resolve a GitHub repository from this workspace.")
        case .loginRequired(let detail):
            state = .failed("\(detail). Sign in to GitHub CLI before repairing organization access.")
        case .permissionRequired(let account, let repository, let detail):
            state = .blocked(account: account, repository: repository, detail: detail)
        case .unavailable(_, let detail):
            state = .failed(detail)
        case .samlAuthorizationRequired:
            state = .failed("GitHub organization authorization is still required.")
        }
    }
}
