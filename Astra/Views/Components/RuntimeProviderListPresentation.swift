import Foundation
import ASTRACore

enum RuntimeProviderRowState: Equatable {
    case checking
    case installing
    /// A sign-in session launched from ASTRA is in flight for this runtime.
    case awaitingSignIn
    case selectedReady
    case ready
    /// Installed, but the provider has no cheap auth probe (Copilot,
    /// Antigravity) — never rendered as a hard green "ready".
    case unverified
    case unauthenticated
    case unresponsive
    case missing
    case unknown
}

/// The single trailing action a runtime row offers. Computed in the pure
/// mapper so the view has zero conditional logic — and so the dead-end
/// "Install" press for runtimes without an install plan is impossible.
enum RuntimeProviderRowAction: Equatable {
    case use
    case signIn
    case install(displayCommand: String)
    case openInstallPage(URL)
    case cancelInstall
    case cancelSignIn
    case none
}

/// Per-runtime auth knowledge layered on top of the binary HealthStatus.
/// `.unknown` keeps the legacy behaviour (installed = green).
enum RuntimeProviderAuthState: Equatable {
    case unknown
    case authenticated
    case unauthenticated(detail: String)
    case unverified(note: String)
}

struct RuntimeProviderRowPresentation: Equatable, Identifiable {
    let id: AgentRuntimeID
    let title: String
    let subtitle: String
    let state: RuntimeProviderRowState
    let isSelected: Bool
    let isInstalled: Bool
    let installCommand: String?
    var primaryAction: RuntimeProviderRowAction = .none
}

enum RuntimeProviderListPresentation {
    /// Runtimes surfaced first inside each section.
    static let recommendedOrder: [AgentRuntimeID] = [.claudeCode, .copilotCLI]

    static func row(
        runtime: AgentRuntimeID,
        descriptor: AgentRuntimeDescriptor,
        selectedRuntime: AgentRuntimeID,
        status: HealthStatus?,
        isProbing: Bool,
        installingRuntime: AgentRuntimeID?,
        installCommand: String?,
        authState: RuntimeProviderAuthState = .unknown,
        signingInRuntime: AgentRuntimeID? = nil,
        installPageURL: URL? = nil
    ) -> RuntimeProviderRowPresentation {
        let isSelected = runtime == selectedRuntime

        func make(
            subtitle: String,
            state: RuntimeProviderRowState,
            isInstalled: Bool
        ) -> RuntimeProviderRowPresentation {
            RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: subtitle,
                state: state,
                isSelected: isSelected,
                isInstalled: isInstalled,
                installCommand: installCommand,
                primaryAction: action(
                    state: state,
                    isSelected: isSelected,
                    installCommand: installCommand,
                    installPageURL: installPageURL
                )
            )
        }

        if installingRuntime == runtime {
            return make(
                subtitle: installCommand ?? "Installing...",
                state: .installing,
                isInstalled: false
            )
        }

        if signingInRuntime == runtime {
            return make(
                subtitle: "Waiting for sign-in...",
                state: .awaitingSignIn,
                isInstalled: isInstalledStatus(status)
            )
        }

        if isProbing {
            return make(
                subtitle: "Checking...",
                state: .checking,
                isInstalled: isInstalledStatus(status)
            )
        }

        switch status {
        case .healthy(_, let version):
            switch authState {
            case .unauthenticated(let detail):
                return make(
                    subtitle: detail.isEmpty ? "Installed, but signed out" : detail,
                    state: .unauthenticated,
                    isInstalled: true
                )
            case .unverified(let note):
                return make(
                    subtitle: note,
                    state: .unverified,
                    isInstalled: true
                )
            case .unknown, .authenticated:
                return make(
                    subtitle: isSelected ? "Selected and ready" : installedSubtitle(version: version),
                    state: isSelected ? .selectedReady : .ready,
                    isInstalled: true
                )
            }
        case .unauthenticated(let detail):
            return make(subtitle: detail, state: .unauthenticated, isInstalled: true)
        case .unresponsive(let detail):
            return make(subtitle: detail, state: .unresponsive, isInstalled: true)
        case .missingBinary:
            return make(
                subtitle: installCommand ?? descriptor.installHint,
                state: .missing,
                isInstalled: false
            )
        case .none:
            return make(subtitle: "Not checked yet", state: .unknown, isInstalled: false)
        }
    }

    /// Groups rows for the redesigned runtime step: a calm "ready" block,
    /// an attention block that only appears when needed, and a collapsed
    /// "not installed" block that bounds the step's height as the
    /// runtime registry grows.
    struct Sections: Equatable {
        let ready: [RuntimeProviderRowPresentation]
        let needsAttention: [RuntimeProviderRowPresentation]
        let notInstalled: [RuntimeProviderRowPresentation]
    }

    static func sections(rows: [RuntimeProviderRowPresentation]) -> Sections {
        var ready: [RuntimeProviderRowPresentation] = []
        var attention: [RuntimeProviderRowPresentation] = []
        var notInstalled: [RuntimeProviderRowPresentation] = []

        for row in rows {
            switch row.state {
            case .selectedReady, .ready, .unverified:
                ready.append(row)
            case .unauthenticated, .unresponsive, .awaitingSignIn, .installing:
                // Installing stays in the always-visible block — progress
                // and Cancel must not hide inside a collapsed disclosure.
                attention.append(row)
            case .missing, .unknown:
                notInstalled.append(row)
            case .checking:
                if row.isInstalled {
                    ready.append(row)
                } else {
                    notInstalled.append(row)
                }
            }
        }

        return Sections(
            ready: recommendedFirst(ready),
            needsAttention: recommendedFirst(attention),
            notInstalled: recommendedFirst(notInstalled)
        )
    }

    private static func recommendedFirst(
        _ rows: [RuntimeProviderRowPresentation]
    ) -> [RuntimeProviderRowPresentation] {
        rows.enumerated().sorted { lhs, rhs in
            let lhsRank = recommendedOrder.firstIndex(of: lhs.element.id) ?? Int.max
            let rhsRank = recommendedOrder.firstIndex(of: rhs.element.id) ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private static func action(
        state: RuntimeProviderRowState,
        isSelected: Bool,
        installCommand: String?,
        installPageURL: URL?
    ) -> RuntimeProviderRowAction {
        switch state {
        case .installing:
            return .cancelInstall
        case .awaitingSignIn:
            return .cancelSignIn
        case .checking, .selectedReady, .unknown:
            return .none
        case .ready, .unverified, .unresponsive:
            return isSelected ? .none : .use
        case .unauthenticated:
            return .signIn
        case .missing:
            if let installCommand {
                return .install(displayCommand: installCommand)
            }
            if let installPageURL {
                return .openInstallPage(installPageURL)
            }
            return .none
        }
    }

    private static func installedSubtitle(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Installed" : "Installed - \(trimmed)"
    }

    private static func isInstalledStatus(_ status: HealthStatus?) -> Bool {
        switch status {
        case .healthy, .unauthenticated, .unresponsive:
            return true
        case .missingBinary, .none:
            return false
        }
    }
}
