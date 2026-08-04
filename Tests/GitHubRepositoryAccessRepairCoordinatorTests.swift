import Foundation
import Testing
@testable import ASTRA
import ASTRACore

private struct ImmediateGitHubDeviceCodeMonitor: GitHubDeviceCodeMonitoring {
    let detectsCode: Bool

    @MainActor
    func snapshot() -> GitHubPasteboardSnapshot {
        GitHubPasteboardSnapshot(changeCount: 10, string: "previous")
    }

    func waitForNewCode(
        after _: GitHubPasteboardSnapshot,
        timeout _: TimeInterval
    ) async -> String? {
        detectsCode ? "ABCD-1234" : nil
    }
}

private struct DelayedGitHubDeviceCodeMonitor: GitHubDeviceCodeMonitoring {
    @MainActor
    func snapshot() -> GitHubPasteboardSnapshot {
        GitHubPasteboardSnapshot(changeCount: 10, string: "previous")
    }

    func waitForNewCode(
        after _: GitHubPasteboardSnapshot,
        timeout _: TimeInterval
    ) async -> String? {
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            return nil
        }
        return nil
    }
}

@MainActor
private final class RecordingGitHubURLLauncher: GitHubAuthorizationURLLaunching, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []
    var succeeds = true

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return succeeds
    }
}

private actor GitHubRefreshRunnerStub: BinaryRunner {
    struct Call: Sendable {
        let path: String
        let args: [String]
        let environment: [String: String]?
    }

    private let result: RunResult
    private let delayNanoseconds: UInt64
    private(set) var calls: [Call] = []

    init(result: RunResult, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func run(
        path: String,
        args: [String],
        timeout _: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        calls.append(Call(path: path, args: args, environment: environment))
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return .cancelled(stdout: "", stderr: "")
            }
        }
        return result
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private actor SequencedGitHubRepairProbe {
    private var statuses: [GitHubRepositoryAccessStatus]
    private(set) var callCount = 0

    init(_ statuses: [GitHubRepositoryAccessStatus]) {
        self.statuses = statuses
    }

    func call(ghPath _: String, workingDirectory _: String) -> GitHubRepositoryAccessStatus {
        callCount += 1
        if statuses.count > 1 {
            return statuses.removeFirst()
        }
        return statuses[0]
    }

    func calls() -> Int {
        callCount
    }
}

private actor GitHubRefreshOutcomeStub {
    private let outcome: GitHubCLIAuthenticationRefreshOutcome
    private(set) var callCount = 0

    init(_ outcome: GitHubCLIAuthenticationRefreshOutcome) {
        self.outcome = outcome
    }

    func call(
        ghPath _: String,
        onDeviceCode _: @escaping GitHubDeviceCodeHandler
    ) -> GitHubCLIAuthenticationRefreshOutcome {
        callCount += 1
        return outcome
    }

    func calls() -> Int {
        callCount
    }
}

private actor SuspendedGitHubRefreshStub {
    private var continuation: CheckedContinuation<GitHubCLIAuthenticationRefreshOutcome, Never>?
    private var pendingOutcome: GitHubCLIAuthenticationRefreshOutcome?

    func call(
        onDeviceCode: @escaping GitHubDeviceCodeHandler
    ) async -> GitHubCLIAuthenticationRefreshOutcome {
        await onDeviceCode("ABCD-1234")
        if let pendingOutcome {
            return pendingOutcome
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ outcome: GitHubCLIAuthenticationRefreshOutcome) {
        guard let continuation else {
            pendingOutcome = outcome
            return
        }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}

@Suite("GitHub CLI authentication refresher")
struct GitHubCLIAuthenticationRefresherTests {
    @Test("Runs device refresh, reports the code, and preserves the resolved CLI path")
    @MainActor
    func refreshesThroughDeviceFlow() async {
        let runner = GitHubRefreshRunnerStub(
            result: .exited(code: 0, stdout: "", stderr: "Authentication complete."),
            delayNanoseconds: 20_000_000
        )
        var refresher = GitHubCLIAuthenticationRefresher()
        refresher.runner = runner
        refresher.deviceCodeMonitor = ImmediateGitHubDeviceCodeMonitor(detectsCode: true)
        refresher.gate = GitHubCredentialRefreshGate()

        var observedCode: String?
        let outcome = await refresher.refresh(ghPath: "/opt/homebrew/bin/gh") {
            observedCode = $0
        }

        #expect(outcome == .refreshed)
        #expect(observedCode == "ABCD-1234")
        let calls = await runner.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls[0].path == "/opt/homebrew/bin/gh")
        #expect(calls[0].args == [
            "auth", "refresh",
            "--hostname", "github.com",
            "--clipboard"
        ])
        #expect(calls[0].environment?["LC_ALL"] == "C")
        #expect(calls[0].environment?["NO_COLOR"] == "1")
    }

    @Test("CLI failure returns immediately and redacts transient values")
    @MainActor
    func cliFailureIsSafeAndActionable() async {
        let runner = GitHubRefreshRunnerStub(result: .exited(
            code: 1,
            stdout: "",
            stderr: "Device ABCD-1234 failed at https://github.com/login/device"
        ))
        var refresher = GitHubCLIAuthenticationRefresher()
        refresher.runner = runner
        refresher.deviceCodeMonitor = DelayedGitHubDeviceCodeMonitor()
        refresher.gate = GitHubCredentialRefreshGate()

        let outcome = await refresher.refresh(ghPath: "/opt/homebrew/bin/gh")

        guard case .failed(let detail) = outcome else {
            Issue.record("Expected a typed CLI failure, got \(outcome)")
            return
        }
        #expect(detail.contains("ABCD-1234") == false)
        #expect(detail.contains("github.com/login/device") == false)
        #expect(detail.contains("[redacted one-time code]"))
    }

    @Test("Missing device code cancels the waiting CLI instead of hanging")
    @MainActor
    func missingDeviceCodeFailsFast() async {
        let runner = GitHubRefreshRunnerStub(
            result: .timedOut(stdout: "", stderr: ""),
            delayNanoseconds: 5_000_000_000
        )
        var refresher = GitHubCLIAuthenticationRefresher()
        refresher.runner = runner
        refresher.deviceCodeMonitor = ImmediateGitHubDeviceCodeMonitor(detectsCode: false)
        refresher.gate = GitHubCredentialRefreshGate()

        let outcome = await refresher.refresh(ghPath: "/opt/homebrew/bin/gh")

        #expect(outcome == .deviceCodeUnavailable)
    }

    @Test("Device code recognition rejects stale or malformed clipboard text")
    func deviceCodeValidationIsStrict() {
        #expect(SystemGitHubDeviceCodeMonitor.isGitHubDeviceCode("ABCD-1234"))
        #expect(SystemGitHubDeviceCodeMonitor.isGitHubDeviceCode(" abcd-1234 ") == false)
        #expect(SystemGitHubDeviceCodeMonitor.isGitHubDeviceCode("ABCD1234") == false)
        #expect(SystemGitHubDeviceCodeMonitor.isGitHubDeviceCode(nil) == false)
    }

    @Test("Credential refresh gate serializes token replacement")
    @MainActor
    func credentialRefreshGateSerializes() async {
        let gate = GitHubCredentialRefreshGate()
        #expect(await gate.admission() == .acquired)
        #expect(await gate.admission() == .wait(afterGeneration: 0))
        var observedCode: String?
        let waiting = Task {
            await gate.waitForCurrentRefresh(afterGeneration: 0) {
                observedCode = $0
            }
        }
        await Task.yield()
        await gate.publishDeviceCode("ABCD-1234")
        await gate.finish(.refreshed)
        #expect(await waiting.value == .refreshed)
        #expect(observedCode == "ABCD-1234")
        #expect(await gate.admission() == .acquired)
        await gate.finish(.cancelled)
    }
}

@Suite("GitHub repository access repair coordinator")
@MainActor
struct GitHubRepositoryAccessRepairCoordinatorTests {
    private let firstURL = URL(
        string: "https://github.com/enterprises/stanford-university/sso?authorization_request=FIRST"
    )!
    private let refreshedURL = URL(
        string: "https://github.com/enterprises/stanford-university/sso?authorization_request=SECOND"
    )!

    @Test("Coordinates current SSO, credential refresh, fresh SSO, and repository verification")
    func completeRepairSequence() async {
        let probe = SequencedGitHubRepairProbe([
            saml(url: firstURL),
            saml(url: firstURL),
            saml(url: refreshedURL),
            .ready(account: "aandresalvarez", repository: "susom/starr-data-lake")
        ])
        let refresh = GitHubRefreshOutcomeStub(.refreshed)
        let launcher = RecordingGitHubURLLauncher()
        let coordinator = makeCoordinator(probe: probe, refresh: refresh, launcher: launcher)

        coordinator.start(workingDirectory: "/workspace/repo")
        await coordinator.waitForCurrentOperation()
        #expect(coordinator.state == .awaitingAuthorization(
            stage: .currentCredential,
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
        #expect(launcher.openedURLs == [firstURL])

        coordinator.verifyNow()
        await coordinator.waitForCurrentOperation()
        #expect(await refresh.calls() == 1)
        #expect(coordinator.state == .awaitingAuthorization(
            stage: .refreshedCredential,
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
        #expect(launcher.openedURLs == [firstURL, refreshedURL])

        coordinator.verifyNow()
        await coordinator.waitForCurrentOperation()
        #expect(coordinator.state == .ready(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
        #expect(await probe.calls() == 4)
    }

    @Test("Final SSO rejection is a terminal external-policy blocker, not another loop")
    func persistentSSOBecomesPolicyBlock() async {
        let probe = SequencedGitHubRepairProbe([
            saml(url: firstURL),
            saml(url: firstURL),
            saml(url: refreshedURL),
            saml(url: refreshedURL)
        ])
        let refresh = GitHubRefreshOutcomeStub(.refreshed)
        let launcher = RecordingGitHubURLLauncher()
        let coordinator = makeCoordinator(probe: probe, refresh: refresh, launcher: launcher)

        coordinator.start(workingDirectory: "/workspace/repo")
        await coordinator.waitForCurrentOperation()
        coordinator.verifyNow()
        await coordinator.waitForCurrentOperation()
        coordinator.verifyNow()
        await coordinator.waitForCurrentOperation()

        guard case .blocked(let account, let repository, let detail) = coordinator.state else {
            Issue.record("Expected an external policy blocker, got \(coordinator.state)")
            return
        }
        #expect(account == "aandresalvarez")
        #expect(repository == "susom/starr-data-lake")
        #expect(detail.contains("still did not authorize"))
        #expect(detail.contains("organization owner"))
        #expect(launcher.openedURLs == [firstURL, refreshedURL])
    }

    @Test("App activation only continues repair after a real external transition")
    func activationRequiresResign() async {
        let probe = SequencedGitHubRepairProbe([
            saml(url: firstURL),
            .ready(account: "aandresalvarez", repository: "susom/starr-data-lake")
        ])
        let refresh = GitHubRefreshOutcomeStub(.refreshed)
        let launcher = RecordingGitHubURLLauncher()
        let coordinator = makeCoordinator(probe: probe, refresh: refresh, launcher: launcher)

        coordinator.start(workingDirectory: "/workspace/repo")
        await coordinator.waitForCurrentOperation()
        coordinator.applicationDidBecomeActive()
        await coordinator.waitForCurrentOperation()
        #expect(await probe.calls() == 1)

        coordinator.applicationDidResignActive()
        coordinator.applicationDidBecomeActive()
        await coordinator.waitForCurrentOperation()
        #expect(coordinator.state == .ready(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
    }

    @Test("Automatic focus return rechecks but never rotates credentials without another user action")
    func automaticReturnDoesNotAdvanceCredentialRepair() async {
        let probe = SequencedGitHubRepairProbe([
            saml(url: firstURL),
            saml(url: firstURL),
            saml(url: firstURL),
            saml(url: refreshedURL)
        ])
        let refresh = GitHubRefreshOutcomeStub(.refreshed)
        let launcher = RecordingGitHubURLLauncher()
        let coordinator = makeCoordinator(probe: probe, refresh: refresh, launcher: launcher)

        coordinator.start(workingDirectory: "/workspace/repo")
        await coordinator.waitForCurrentOperation()
        coordinator.applicationDidResignActive()
        coordinator.applicationDidBecomeActive()
        await coordinator.waitForCurrentOperation()

        #expect(coordinator.state == .authorizationStillRequired(
            stage: .currentCredential,
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
        #expect(await refresh.calls() == 0)

        coordinator.verifyNow()
        await coordinator.waitForCurrentOperation()
        #expect(await refresh.calls() == 1)
        #expect(coordinator.state == .awaitingAuthorization(
            stage: .refreshedCredential,
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
    }

    @Test("A refresh cancellation still accepts repository access proven afterward")
    func cancellationReprobesBeforeFailing() async {
        let probe = SequencedGitHubRepairProbe([
            saml(url: firstURL),
            saml(url: firstURL),
            .ready(account: "aandresalvarez", repository: "susom/starr-data-lake")
        ])
        let refresh = GitHubRefreshOutcomeStub(.cancelled)
        let launcher = RecordingGitHubURLLauncher()
        let coordinator = makeCoordinator(probe: probe, refresh: refresh, launcher: launcher)

        coordinator.start(workingDirectory: "/workspace/repo")
        await coordinator.waitForCurrentOperation()
        coordinator.verifyNow()
        await coordinator.waitForCurrentOperation()

        #expect(coordinator.state == .ready(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
    }

    @Test("Device code stays visible while GitHub waits for browser approval")
    func deviceCodeStaysVisibleDuringApproval() async {
        let probe = SequencedGitHubRepairProbe([
            saml(url: firstURL),
            saml(url: firstURL),
            saml(url: refreshedURL)
        ])
        let refresh = SuspendedGitHubRefreshStub()
        let launcher = RecordingGitHubURLLauncher()
        let coordinator = GitHubRepositoryAccessRepairCoordinator(
            probe: { ghPath, workingDirectory in
                await probe.call(ghPath: ghPath, workingDirectory: workingDirectory)
            },
            refreshCredential: { _, onDeviceCode in
                await refresh.call(onDeviceCode: onDeviceCode)
            },
            urlLauncher: launcher,
            detectExecutable: { _ in "/opt/homebrew/bin/gh" },
            isApplicationActive: { true },
            observesApplicationLifecycle: false
        )

        coordinator.start(workingDirectory: "/workspace/repo")
        await coordinator.waitForCurrentOperation()
        coordinator.verifyNow()
        for _ in 0..<100 where coordinator.state.deviceCode == nil {
            await Task.yield()
        }

        #expect(coordinator.state == .awaitingDeviceAuthorization(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake",
            code: "ABCD-1234"
        ))
        #expect(coordinator.state.summary?.contains("ABCD-1234") == true)

        await refresh.finish(.refreshed)
        await coordinator.waitForCurrentOperation()
        #expect(coordinator.state == .awaitingAuthorization(
            stage: .refreshedCredential,
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
    }

    private func saml(url: URL) -> GitHubRepositoryAccessStatus {
        .samlAuthorizationRequired(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake",
            organization: "susom",
            authorizationURL: url
        )
    }

    private func makeCoordinator(
        probe: SequencedGitHubRepairProbe,
        refresh: GitHubRefreshOutcomeStub,
        launcher: RecordingGitHubURLLauncher
    ) -> GitHubRepositoryAccessRepairCoordinator {
        GitHubRepositoryAccessRepairCoordinator(
            probe: { ghPath, workingDirectory in
                await probe.call(ghPath: ghPath, workingDirectory: workingDirectory)
            },
            refreshCredential: { ghPath, onDeviceCode in
                await refresh.call(
                    ghPath: ghPath,
                    onDeviceCode: onDeviceCode
                )
            },
            urlLauncher: launcher,
            detectExecutable: { _ in "/opt/homebrew/bin/gh" },
            isApplicationActive: { true },
            observesApplicationLifecycle: false
        )
    }
}
