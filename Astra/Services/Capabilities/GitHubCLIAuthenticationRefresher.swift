import AppKit
import Foundation
import ASTRACore

struct GitHubPasteboardSnapshot: Equatable, Sendable {
    let changeCount: Int
    let string: String?
}

typealias GitHubDeviceCodeHandler = @MainActor @Sendable (String) -> Void

protocol GitHubDeviceCodeMonitoring: Sendable {
    @MainActor func snapshot() -> GitHubPasteboardSnapshot
    func waitForNewCode(
        after baseline: GitHubPasteboardSnapshot,
        timeout: TimeInterval
    ) async -> String?
}

struct SystemGitHubDeviceCodeMonitor: GitHubDeviceCodeMonitoring {
    var pollInterval: TimeInterval = 0.1
    var sleep: @Sendable (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    @MainActor
    func snapshot() -> GitHubPasteboardSnapshot {
        GitHubPasteboardSnapshot(
            changeCount: NSPasteboard.general.changeCount,
            string: NSPasteboard.general.string(forType: .string)
        )
    }

    func waitForNewCode(
        after baseline: GitHubPasteboardSnapshot,
        timeout: TimeInterval
    ) async -> String? {
        var elapsed: TimeInterval = 0
        while elapsed < timeout {
            if Task.isCancelled { return nil }
            let current = await snapshot()
            if current.changeCount != baseline.changeCount,
               current.string != baseline.string,
               Self.isGitHubDeviceCode(current.string) {
                return current.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            do {
                try await sleep(pollInterval)
            } catch {
                return nil
            }
            elapsed += pollInterval
        }
        return nil
    }

    static func isGitHubDeviceCode(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#,
            options: .regularExpression
        ) != nil
    }
}

protocol GitHubAuthorizationURLLaunching: Sendable {
    @MainActor func open(_ url: URL) -> Bool
}

struct SystemGitHubAuthorizationURLLauncher: GitHubAuthorizationURLLaunching {
    @MainActor
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

enum GitHubCLIAuthenticationRefreshOutcome: Equatable, Sendable {
    case refreshed
    case deviceCodeUnavailable
    case timedOut
    case cancelled
    case failed(String)

    var failureDetail: String? {
        switch self {
        case .refreshed:
            nil
        case .deviceCodeUnavailable:
            "GitHub CLI did not provide a browser device code. Update GitHub CLI or verify that its active credential is stored in the system keyring."
        case .timedOut:
            "GitHub authorization was not completed within five minutes."
        case .cancelled:
            "GitHub authorization was cancelled."
        case .failed(let detail):
            detail
        }
    }
}

actor GitHubCredentialRefreshGate {
    private struct Waiter {
        let continuation: CheckedContinuation<GitHubCLIAuthenticationRefreshOutcome, Never>
        let onDeviceCode: GitHubDeviceCodeHandler
    }

    enum Admission: Equatable, Sendable {
        case acquired
        case wait(afterGeneration: Int)
    }

    static let shared = GitHubCredentialRefreshGate()

    private var isRefreshing = false
    private var generation = 0
    private var lastOutcome: GitHubCLIAuthenticationRefreshOutcome?
    private var currentDeviceCode: String?
    private var waiters: [Waiter] = []

    func admission() -> Admission {
        guard !isRefreshing else { return .wait(afterGeneration: generation) }
        isRefreshing = true
        return .acquired
    }

    func finish(_ outcome: GitHubCLIAuthenticationRefreshOutcome) {
        isRefreshing = false
        generation += 1
        lastOutcome = outcome
        currentDeviceCode = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: outcome)
        }
    }

    func publishDeviceCode(_ code: String) async {
        currentDeviceCode = code
        for waiter in waiters {
            await waiter.onDeviceCode(code)
        }
    }

    func waitForCurrentRefresh(
        afterGeneration observedGeneration: Int,
        onDeviceCode: @escaping GitHubDeviceCodeHandler
    ) async -> GitHubCLIAuthenticationRefreshOutcome {
        if let currentDeviceCode {
            await onDeviceCode(currentDeviceCode)
        }
        if generation > observedGeneration, let lastOutcome {
            return lastOutcome
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(
                continuation: continuation,
                onDeviceCode: onDeviceCode
            ))
        }
    }
}

struct GitHubCLIAuthenticationRefresher: Sendable {
    private enum Event: Sendable {
        case processFinished(RunResult)
        case deviceCodeDetected(String?)
    }

    var runner: any BinaryRunner = ProcessBinaryRunner()
    var deviceCodeMonitor: any GitHubDeviceCodeMonitoring = SystemGitHubDeviceCodeMonitor()
    var gate: GitHubCredentialRefreshGate = .shared
    var deviceCodeTimeout: TimeInterval = 30
    var completionTimeout: TimeInterval = 300

    static let deviceAuthorizationURL = URL(string: "https://github.com/login/device")!

    func refresh(
        ghPath: String,
        onDeviceCode: @escaping GitHubDeviceCodeHandler = { _ in }
    ) async -> GitHubCLIAuthenticationRefreshOutcome {
        switch await gate.admission() {
        case .acquired:
            let outcome = await performRefresh(
                ghPath: ghPath,
                onDeviceCode: onDeviceCode
            )
            await gate.finish(outcome)
            return outcome
        case .wait(let generation):
            return await gate.waitForCurrentRefresh(
                afterGeneration: generation,
                onDeviceCode: onDeviceCode
            )
        }
    }

    private func performRefresh(
        ghPath: String,
        onDeviceCode: @escaping GitHubDeviceCodeHandler
    ) async -> GitHubCLIAuthenticationRefreshOutcome {
        let baseline = await deviceCodeMonitor.snapshot()
        let environment = RuntimeProcessEnvironment.enriched(extraVariables: [
            "LC_ALL": "C",
            "LANG": "C",
            "NO_COLOR": "1"
        ])

        return await withTaskGroup(
            of: Event.self,
            returning: GitHubCLIAuthenticationRefreshOutcome.self
        ) { group in
            group.addTask {
                .processFinished(await runner.run(
                    path: ghPath,
                    args: [
                        "auth", "refresh",
                        "--hostname", "github.com",
                        "--clipboard"
                    ],
                    timeout: completionTimeout,
                    environment: environment
                ))
            }
            group.addTask {
                .deviceCodeDetected(await deviceCodeMonitor.waitForNewCode(
                    after: baseline,
                    timeout: deviceCodeTimeout
                ))
            }

            while let event = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return .cancelled
                }
                switch event {
                case .processFinished(let result):
                    group.cancelAll()
                    return Self.classify(result)
                case .deviceCodeDetected(let code?):
                    await gate.publishDeviceCode(code)
                    await onDeviceCode(code)
                case .deviceCodeDetected(nil):
                    group.cancelAll()
                    return .deviceCodeUnavailable
                }
            }
            return .cancelled
        }
    }

    private static func classify(_ result: RunResult) -> GitHubCLIAuthenticationRefreshOutcome {
        if result.isSuccess { return .refreshed }
        switch result.outcome {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .launchFailed(let reason):
            return .failed("GitHub CLI could not start: \(reason)")
        case .exited(let code):
            let output = [result.stderr, result.stdout]
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(sanitizedDiagnostic)
                ?? ""
            if output.isEmpty {
                return .failed("GitHub CLI credential refresh exited with status \(code).")
            }
            return .failed(output)
        }
    }

    private static func sanitizedDiagnostic(_ value: String) -> String {
        var sanitized = value
            .replacingOccurrences(
                of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#,
                with: "[redacted one-time code]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"https://github\.com/[^\s]+"#,
                with: "[GitHub authorization page]",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.count > 240 {
            sanitized = String(sanitized.prefix(240))
        }
        return sanitized
    }
}
