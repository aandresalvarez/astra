import Foundation
import Testing
@testable import ASTRA

@Suite("Task external operation backend registry")
struct TaskExternalOperationBackendRegistryTests {
    @Test("router dispatches only to an explicitly registered backend kind")
    func routesRegisteredBackend() async {
        let backend = RecordingExternalOperationBackend()
        let router = TaskExternalOperationBackendRouter(registry: .init([
            (kind: "approved_remote_runner", backend: backend)
        ]))
        let request = request(backendKind: "approved_remote_runner")

        #expect(await router.observe(request) == .init(executionState: .running, health: .healthy))
        #expect(await router.cancel(request) == .init(executionState: .cancelled, health: .healthy))
        #expect(await router.validateOwnership(request))
        #expect(await backend.observationCount == 1)
        #expect(await backend.cancellationCount == 1)
        #expect(await backend.validationCount == 1)
    }

    @Test("unknown and malformed backend kinds fail closed without dispatch")
    func rejectsUnknownAndMalformedKinds() async {
        let backend = RecordingExternalOperationBackend()
        let router = TaskExternalOperationBackendRouter(registry: .init([
            (kind: "approved_remote_runner", backend: backend),
            (kind: "../escape", backend: backend)
        ]))

        for kind in ["missing_backend", "../escape", "REMOTE COMMAND"] {
            let request = request(backendKind: kind)
            #expect(await router.observe(request) == .init(executionState: .unknown, health: .malformed))
            #expect(await router.cancel(request) == .init(executionState: .unknown, health: .malformed))
            #expect(await !router.validateOwnership(request))
        }
        #expect(await backend.observationCount == 0)
        #expect(await backend.cancellationCount == 0)
        #expect(await backend.validationCount == 0)
    }

    private func request(backendKind: String) -> TaskExternalOperationBackendRequest {
        .init(
            operationID: UUID(),
            taskID: UUID(),
            originatingRunID: UUID(),
            externalIdentity: "safe:identity",
            backendKind: backendKind,
            backendJobID: "job-safe"
        )
    }
}

private actor RecordingExternalOperationBackend: TaskExternalOperationBackend {
    private(set) var observationCount = 0
    private(set) var cancellationCount = 0
    private(set) var validationCount = 0

    func observe(_: TaskExternalOperationBackendRequest) -> TaskExternalOperationObservation {
        observationCount += 1
        return .init(executionState: .running, health: .healthy)
    }

    func cancel(_: TaskExternalOperationBackendRequest) -> TaskExternalOperationObservation {
        cancellationCount += 1
        return .init(executionState: .cancelled, health: .healthy)
    }

    func validateOwnership(_: TaskExternalOperationBackendRequest) -> Bool {
        validationCount += 1
        return true
    }
}
