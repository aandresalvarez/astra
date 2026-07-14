import Foundation
import ASTRACore

struct OnboardingRuntimeInstallFailurePresentation: Equatable {
    let summary: String
    let detail: String?
    let output: String?
}

/// Pure projection for recovery information layered on top of the shared
/// runtime row. The condensed onboarding chooser must not discard state owned
/// by `RuntimeSetupModel` just because its default row is intentionally lean.
enum OnboardingRuntimeChooserPresentation {
    static let recheckActionTitle = "Re-check runtimes"

    static func selectedBlocker(
        for row: RuntimeProviderRowPresentation,
        blockers: [RuntimeReadinessCheck]
    ) -> RuntimeReadinessCheck? {
        guard row.isSelected else { return nil }
        switch row.state {
        case .unauthenticated, .awaitingSignIn:
            return nil
        default:
            return blockers.first
        }
    }

    static func subtitle(
        for row: RuntimeProviderRowPresentation,
        authSessionStatus: String?,
        selectedBlocker: RuntimeReadinessCheck?
    ) -> String {
        if let authSessionStatus, !authSessionStatus.isEmpty {
            return authSessionStatus
        }
        if let selectedBlocker {
            return "Needs setup — \(selectedBlocker.title)"
        }
        switch row.state {
        case .selectedReady: return "Installed and signed in"
        case .ready: return "Installed"
        case .missing: return "Not installed"
        case .checking: return "Checking installation and sign-in"
        case .installing: return "Installing"
        case .awaitingSignIn: return "Waiting for sign-in"
        case .unauthenticated: return "Installed; sign-in required"
        case .unresponsive: return "Installed; not responding"
        case .unknown: return "Not checked yet"
        case .unverified: return row.subtitle
        }
    }

    static func installFailure(
        for runtime: AgentRuntimeID,
        result: RuntimeCLIInstallResult?
    ) -> OnboardingRuntimeInstallFailurePresentation? {
        guard let result,
              result.runtime == runtime,
              !result.succeeded else {
            return nil
        }
        return OnboardingRuntimeInstallFailurePresentation(
            summary: result.summary,
            detail: result.detail,
            output: result.fullLog
        )
    }
}
