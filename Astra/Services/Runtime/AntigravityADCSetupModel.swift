import AppKit
import Foundation

/// Settings-page state for the Antigravity ADC route: the project the user
/// types, what gcloud's credentials currently say, and one in-flight setup.
///
/// The project field is only the input to the gcloud commands. It is seeded
/// from the credentials' own `quota_project_id` and never persisted by ASTRA,
/// so gcloud stays the single owner of which project `agy` bills against.
@MainActor
final class AntigravityADCSetupModel: ObservableObject {
    @Published var project = ""
    @Published private(set) var credentialStatus: AntigravityADCStatus?
    @Published private(set) var progress: String?
    @Published private(set) var result: AntigravityADCSetupOutcome?
    @Published private(set) var isRunning = false

    private let service: AntigravityADCSetupService
    private let copyToPasteboard: (String) -> Void
    private var setupTask: Task<Void, Never>?
    /// Fired after a successful setup so the owner can re-run readiness.
    var onConfigured: (() -> Void)?

    init(
        service: AntigravityADCSetupService = AntigravityADCSetupService(),
        copyToPasteboard: ((String) -> Void)? = nil
    ) {
        self.service = service
        self.copyToPasteboard = copyToPasteboard ?? { command in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    var projectIssue: String? {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return GCPProjectIDValidation.failure(for: trimmed)?.message
    }

    var canSubmit: Bool {
        !isRunning
            && !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && projectIssue == nil
            && credentialStatus != .gcloudMissing
    }

    /// True when credentials exist but bill a different project than the
    /// field names, so only `set-quota-project` is needed, not a new sign-in.
    var needsOnlyQuotaProject: Bool {
        guard case .signedIn(let current) = credentialStatus else { return false }
        let wanted = project.trimmingCharacters(in: .whitespacesAndNewlines)
        return !wanted.isEmpty && current != wanted
    }

    func refreshStatus() {
        let service = service
        Task {
            let observed = await Task.detached { service.status() }.value
            self.credentialStatus = observed
            if self.project.isEmpty, case .signedIn(let quotaProject?) = observed {
                self.project = quotaProject
            }
        }
    }

    func signIn() {
        guard canSubmit else { return }
        let project = project
        let service = service
        start { onPhase in await service.setUp(project: project, onPhase: onPhase) }
    }

    func applyQuotaProject() {
        guard canSubmit else { return }
        let project = project
        let service = service
        start { _ in await service.setQuotaProject(project) }
    }

    func cancel() {
        setupTask?.cancel()
    }

    private func start(
        _ operation: @escaping @Sendable (@escaping @Sendable (AntigravityADCSetupPhase) async -> Void) async -> AntigravityADCSetupOutcome
    ) {
        isRunning = true
        result = nil
        progress = nil
        setupTask = Task { [weak self] in
            let outcome = await operation { [weak self] phase in
                await self?.handle(phase)
            }
            await self?.finish(outcome)
        }
    }

    private func handle(_ phase: AntigravityADCSetupPhase) {
        switch phase {
        case .launched(.scriptedTerminal, _):
            progress = "Choose your Google account in the browser that opens from Terminal."
        case .launched(.manualCopy, let command):
            copyToPasteboard(command)
            progress = "Command copied. Paste it into Terminal and finish signing in."
        case .waitingForSignIn(let elapsed):
            progress = "Waiting for Google Cloud sign-in… (\(elapsed)s)"
        case .settingQuotaProject:
            progress = "Setting the quota project…"
        }
    }

    private func finish(_ outcome: AntigravityADCSetupOutcome) {
        isRunning = false
        progress = nil
        setupTask = nil
        result = outcome
        refreshStatus()
        if case .configured = outcome {
            onConfigured?()
        }
    }
}

extension AntigravityADCSetupOutcome {
    /// One line for the Settings panel; nil for a silent cancel.
    var message: String? {
        switch self {
        case .configured(let project):
            return "Google Cloud credentials are set up and bill \(project)."
        case .quotaProjectFailed(let detail):
            return "Signed in, but gcloud could not use that project: \(detail) Ask the project's administrator to confirm your access."
        case .gcloudUnavailable(let detail):
            return detail
        case .timedOut:
            return "Sign-in did not finish within 5 minutes. Try again when you are ready."
        case .invalidProject(let message):
            return message
        case .gcloudMissing:
            return "The Google Cloud CLI (gcloud) is not installed."
        case .cancelled:
            return nil
        }
    }

    var isSuccess: Bool {
        if case .configured = self { return true }
        return false
    }
}
