import Foundation
import ASTRACore

enum RuntimeProviderRowState: Equatable {
    case checking
    case installing
    case selectedReady
    case ready
    case unauthenticated
    case unresponsive
    case missing
    case unknown
}

struct RuntimeProviderRowPresentation: Equatable, Identifiable {
    let id: AgentRuntimeID
    let title: String
    let subtitle: String
    let state: RuntimeProviderRowState
    let isSelected: Bool
    let isInstalled: Bool
    let installCommand: String?
}

enum RuntimeProviderListPresentation {
    static func row(
        runtime: AgentRuntimeID,
        descriptor: AgentRuntimeDescriptor,
        selectedRuntime: AgentRuntimeID,
        status: HealthStatus?,
        isProbing: Bool,
        installingRuntime: AgentRuntimeID?,
        installCommand: String?
    ) -> RuntimeProviderRowPresentation {
        let isSelected = runtime == selectedRuntime

        if installingRuntime == runtime {
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: installCommand ?? "Installing...",
                state: .installing,
                isSelected: isSelected,
                isInstalled: false,
                installCommand: installCommand
            )
        }

        if isProbing {
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: "Checking...",
                state: .checking,
                isSelected: isSelected,
                isInstalled: false,
                installCommand: installCommand
            )
        }

        switch status {
        case .healthy(_, let version):
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: isSelected ? "Selected and ready" : installedSubtitle(version: version),
                state: isSelected ? .selectedReady : .ready,
                isSelected: isSelected,
                isInstalled: true,
                installCommand: installCommand
            )
        case .unauthenticated(let detail):
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: detail,
                state: .unauthenticated,
                isSelected: isSelected,
                isInstalled: true,
                installCommand: installCommand
            )
        case .unresponsive(let detail):
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: detail,
                state: .unresponsive,
                isSelected: isSelected,
                isInstalled: true,
                installCommand: installCommand
            )
        case .missingBinary:
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: installCommand ?? descriptor.installHint,
                state: .missing,
                isSelected: isSelected,
                isInstalled: false,
                installCommand: installCommand
            )
        case .none:
            return RuntimeProviderRowPresentation(
                id: runtime,
                title: descriptor.displayName,
                subtitle: "Not checked yet",
                state: .unknown,
                isSelected: isSelected,
                isInstalled: false,
                installCommand: installCommand
            )
        }
    }

    private static func installedSubtitle(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Installed" : "Installed - \(trimmed)"
    }
}
