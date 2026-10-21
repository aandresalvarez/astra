import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The composer's eligibility preview used to read the capability catalog, the
/// pack catalog and the approval records from disk on the main actor after
/// every typing pause, and to read them many times per evaluation. It now
/// reads them once, off the main actor, and evaluates with them pinned. These
/// pin the three properties that makes safe: a pinned evaluation does no disk
/// reads, it reaches the same verdict as an unpinned one, and the pin applies
/// only to the default locations, never to a caller's own directory.
///
/// The probe and the pin are task-local, so these tests cannot see or disturb
/// each other or any parallel suite.
@Suite("Capability resolution inputs")
@MainActor
struct CapabilityResolutionInputsTests {
    private typealias Probe = CapabilityResolutionInputs.DiskReadProbe

    private func makeEnvironment() throws -> (
        task: AgentTask,
        container: ModelContainer,
        root: URL
    ) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-cap-inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Inputs", primaryPath: root.path)
        // Enabled packages and packs are what send resolution to the readers;
        // a workspace with neither returns before reaching any of them.
        workspace.enabledCapabilityIDs = PluginCatalog.builtInPackages.prefix(2).map(\.id)
        workspace.enabledPackIDs = ["astra-test-pack"]
        context.insert(workspace)
        let task = AgentTask(
            title: "Inputs task",
            goal: "Summarize the ticket",
            workspace: workspace,
            runtime: .claudeCode
        )
        context.insert(task)
        try context.save()
        return (task, container, root)
    }

    private func request(for task: AgentTask) -> RuntimeEligibilityPreviewRequest {
        .existingTask(
            task: task,
            messageText: "Summarize what you found",
            attachedFiles: [],
            selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            skipPermissions: false,
            providerSettings: .headlessScenario,
            readinessStates: Dictionary(
                uniqueKeysWithValues: AgentRuntimeAdapterRegistry.runtimeIDs.map { ($0, RuntimeReadinessState.ready) }
            ),
            eventRevision: 0
        )
    }

    /// Inputs for the default locations, built in memory so constructing them
    /// reads nothing either.
    private func inMemoryInputs(packCatalog: AstraPackCatalogSnapshot = .init(entries: [], diagnostics: [])) -> CapabilityResolutionInputs {
        let packs = AstraPackCatalog()
        return CapabilityResolutionInputs(
            libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: PluginCatalog.builtInPackages,
            approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [],
            packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL,
            packCatalog: packCatalog
        )
    }

    private func totalReads(_ probe: Probe) -> Int {
        probe.count(.capabilityLibrary) + probe.count(.approvalRecords) + probe.count(.packCatalog)
    }

    @Test("An unpinned evaluation reaches every reader, so the probe measures something")
    func unpinnedEvaluationReadsFromDisk() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let request = request(for: environment.task)
        let probe = Probe()

        _ = await CapabilityResolutionInputs.$diskReadProbe.withValue(probe) {
            await request.evaluate(candidateRuntimes: [request.selectedRuntime])
        }

        #expect(probe.count(.capabilityLibrary) > 0)
        #expect(probe.count(.packCatalog) > 0)
    }

    @Test("A pinned evaluation does no capability disk reads")
    func pinnedEvaluationDoesNoDiskReads() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let request = request(for: environment.task)
        let probe = Probe()

        let snapshot = await CapabilityResolutionInputs.$diskReadProbe.withValue(probe) {
            await CapabilityResolutionInputs.$pinned.withValue(inMemoryInputs()) {
                await request.evaluate()
            }
        }

        #expect(snapshot != nil)
        #expect(totalReads(probe) == 0, "pinned evaluation still read from disk")
    }

    @Test("Pinned inputs loaded from disk give the same verdicts as reading live")
    func pinnedVerdictsMatchLiveVerdicts() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let request = request(for: environment.task)

        let live = try #require(await request.evaluate())
        let inputs = try #require(await CapabilityResolutionInputs.loadDetached())
        let pinned = try #require(await CapabilityResolutionInputs.$pinned.withValue(inputs) {
            await request.evaluate()
        })

        #expect(Set(pinned.candidates.keys) == Set(live.candidates.keys))
        for (runtime, candidate) in live.candidates {
            #expect(pinned.candidates[runtime]?.isEligible == candidate.isEligible, "\(runtime) verdict changed")
            #expect(pinned.candidates[runtime]?.contractDigest == candidate.contractDigest, "\(runtime) contract changed")
        }
        #expect(pinned.launchBlock?.suggestedRuntime == live.launchBlock?.suggestedRuntime)
    }

    @Test("The pin answers only for the default storage locations")
    func pinIgnoresCallerDirectories() throws {
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-cap-inputs-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let probe = Probe()

        CapabilityResolutionInputs.$diskReadProbe.withValue(probe) {
            CapabilityResolutionInputs.$pinned.withValue(inMemoryInputs()) {
                _ = CapabilityRuntimeResourceMatcher.packageDefinitions(library: CapabilityLibrary(directory: other))
                _ = CapabilityApprovalStore(directory: other).records()
                _ = AstraPackCatalog(builtInDirectory: other, localStorageRoot: other).load()
            }
        }

        #expect(probe.count(.capabilityLibrary) == 1)
        #expect(probe.count(.approvalRecords) == 1)
        #expect(probe.count(.packCatalog) == 1)
    }

    @Test("The pin hands back exactly what it holds")
    func pinReturnsPinnedValues() {
        let marker = AstraPackCatalogSnapshot(entries: [], diagnostics: [
            AstraPackCatalogDiagnostic(
                code: .unreadableSource,
                source: AstraPackSource(kind: .local, manifestURL: nil, rootURL: nil, displayName: "marker", rawData: nil),
                message: "pinned-marker",
                validationIssues: []
            )
        ])
        let inputs = inMemoryInputs(packCatalog: marker)

        let (definitions, records, catalog) = CapabilityResolutionInputs.$pinned.withValue(inputs) {
            (
                CapabilityRuntimeResourceMatcher.packageDefinitions(),
                CapabilityApprovalStore().records(),
                AstraPackCatalog().load()
            )
        }

        #expect(definitions.map(\.id) == PluginCatalog.builtInPackages.map(\.id))
        #expect(records.isEmpty)
        #expect(catalog == marker)
    }

    @Test("Loading inside a pin reads the disk rather than echoing the pin")
    func loadIgnoresAnEnclosingPin() {
        let probe = Probe()

        CapabilityResolutionInputs.$diskReadProbe.withValue(probe) {
            CapabilityResolutionInputs.$pinned.withValue(inMemoryInputs()) {
                _ = CapabilityResolutionInputs.load()
            }
        }

        #expect(probe.count(.capabilityLibrary) == 1)
        #expect(probe.count(.approvalRecords) == 1)
        #expect(probe.count(.packCatalog) == 1)
    }

    /// A keystroke cancels the preview while its read may still be running.
    /// The read must stop with it rather than run on beside the next one.
    @Test("A cancelled caller gets no inputs, and its read stops")
    func cancelledLoadReturnsNothing() async {
        let load = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await CapabilityResolutionInputs.loadDetached()
        }
        #expect(await load.value == nil)
    }

    @Test("A load that is told to stop reads no further store")
    func stoppedLoadReadsNoFurtherStore() {
        let probe = Probe()
        var checks = 0
        let inputs = CapabilityResolutionInputs.$diskReadProbe.withValue(probe) {
            CapabilityResolutionInputs.load(
                library: CapabilityLibrary(),
                approvals: CapabilityApprovalStore(),
                packCatalog: AstraPackCatalog(),
                stopIf: {
                    checks += 1
                    return checks > 1
                }
            )
        }

        #expect(inputs == nil)
        #expect(probe.count(.capabilityLibrary) == 1)
        #expect(probe.count(.approvalRecords) == 0)
        #expect(probe.count(.packCatalog) == 0)
    }
}
