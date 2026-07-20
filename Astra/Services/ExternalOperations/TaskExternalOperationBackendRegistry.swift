import Foundation
import ASTRAModels

/// One reviewed backend owns observation, cancellation, and ownership proof
/// for one bounded backend kind. The registry contains concrete capabilities;
/// it never accepts model-provided commands or dynamically loads executors.
protocol TaskExternalOperationBackend:
    TaskExternalOperationObserving,
    TaskExternalOperationCancelling,
    TaskExternalOperationOwnershipValidating
{}

struct TaskExternalOperationBackendRegistry: Sendable {
    private let backends: [String: any TaskExternalOperationBackend]

    init(_ entries: [(kind: String, backend: any TaskExternalOperationBackend)]) {
        var registered: [String: any TaskExternalOperationBackend] = [:]
        for entry in entries {
            guard Self.isValidBackendKind(entry.kind), registered[entry.kind] == nil else { continue }
            registered[entry.kind] = entry.backend
        }
        backends = registered
    }

    func backend(for kind: String) -> (any TaskExternalOperationBackend)? {
        guard Self.isValidBackendKind(kind) else { return nil }
        return backends[kind]
    }

    static func isValidBackendKind(_ kind: String) -> Bool {
        kind.range(of: #"^[a-z][a-z0-9_]{0,79}$"#, options: .regularExpression) != nil
    }
}

struct TaskExternalOperationBackendRouter:
    TaskExternalOperationObserving,
    TaskExternalOperationCancelling,
    TaskExternalOperationOwnershipValidating,
    Sendable
{
    let registry: TaskExternalOperationBackendRegistry

    func observe(_ request: TaskExternalOperationBackendRequest) async -> TaskExternalOperationObservation {
        guard let backend = registry.backend(for: request.backendKind) else {
            return .init(executionState: .unknown, health: .malformed)
        }
        return await backend.observe(request)
    }

    func cancel(_ request: TaskExternalOperationBackendRequest) async -> TaskExternalOperationObservation {
        guard let backend = registry.backend(for: request.backendKind) else {
            return .init(executionState: .unknown, health: .malformed)
        }
        return await backend.cancel(request)
    }

    func validateOwnership(_ request: TaskExternalOperationBackendRequest) async -> Bool {
        guard let backend = registry.backend(for: request.backendKind) else { return false }
        return await backend.validateOwnership(request)
    }
}

extension WorkspaceManagedJobExternalOperationBackend: TaskExternalOperationBackend {}
