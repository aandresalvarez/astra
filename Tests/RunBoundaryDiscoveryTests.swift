import Testing
import Foundation

/// Ordering guarantees for the pass that collects what a finished run left
/// behind. Checked against the source because the property is about where the
/// calls sit relative to the worker's remaining `await`s, which no in-process
/// run of the happy path can observe.
@Suite("Run boundary discovery")
struct RunBoundaryDiscoveryOrderingTests {

    /// A staged proposal exists on disk the moment the broker returns, but the
    /// pending event that makes it reviewable lives in the `ModelContext` until
    /// something saves. After discovery the worker goes on to deliverable
    /// verification, tests, an AI check, baseline verification and a handoff
    /// scan — minutes of `await`s. An exit anywhere in there used to lose the
    /// event while leaving the write behind, and nothing rescans the staging
    /// directory at launch: the proposal simply never surfaced.
    @Test("Discovered connector mutations are persisted before the worker awaits again")
    func discoveredConnectorMutationsArePersistedBeforeTheNextAwait() throws {
        let runtime = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Runtime")
        let workerSource = try String(
            contentsOf: runtime.appendingPathComponent("AgentRuntimeWorker.swift"),
            encoding: .utf8
        )
        // The block moved out of the worker when withheld-credential offers
        // joined staged mutations as things a finished run leaves for the user.
        // The worker still has to reach it, or the discovery it guarantees
        // never runs.
        #expect(sourceContains(workerSource, "RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser("))

        let boundarySource = try String(
            contentsOf: runtime.appendingPathComponent("RunBoundaryDiscovery.swift"),
            encoding: .utf8
        )
        let discovery = try #require(
            boundarySource.range(of: "ConnectorMutationDiscovery.recordStagedMutations(")
        )
        let afterDiscovery = boundarySource[discovery.upperBound...]
        let save = try #require(
            afterDiscovery.range(of: "WorkspacePersistenceCoordinator.saveAndAutoExport("),
            "Discovery no longer persists its events; they are lost on any later exit."
        )
        if let nextAwait = afterDiscovery.range(of: "await ") {
            #expect(
                save.lowerBound < nextAwait.lowerBound,
                "The run boundary awaits again before saving the proposals it just discovered."
            )
        }
        // A refused save is a proposal the user will never be offered, which is
        // exactly the condition that has to be reportable afterwards.
        #expect(sourceContains(boundarySource, "connector_mutation_discovery_unpersisted"))
    }

    private func sourceContains(_ source: String, _ expected: String) -> Bool {
        normalizeWhitespace(source).contains(normalizeWhitespace(expected))
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
