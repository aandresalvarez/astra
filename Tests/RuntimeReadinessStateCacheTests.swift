import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("Runtime readiness state cache")
struct RuntimeReadinessStateCacheTests {
    private func configuration(claudePath: String = "/opt/claude") -> RuntimeProviderAvailabilityConfiguration {
        RuntimeProviderAvailabilityConfiguration(
            claudePath: claudePath,
            copilotPath: "/opt/copilot",
            claudeProvider: .vertex,
            vertexProjectID: "project-1",
            vertexRegion: "global",
            vertexOpusModel: "claude-opus-4-6@default",
            vertexSonnetModel: "claude-sonnet-4-6@default",
            vertexHaikuModel: "claude-haiku-4-5@20251001"
        )
    }

    /// Opening a task must show its provider immediately: the answer for the
    /// same settings is served until it ages out or the settings change.
    @Test("Cached readiness is served for the same settings until it ages out")
    func cacheServesSameSettingsUntilExpiry() async {
        let cache = RuntimeReadinessStateCache()
        let states: [AgentRuntimeID: RuntimeReadinessState] = [.claudeCode: .ready, .copilotCLI: .blocked]
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        await cache.store(states, for: configuration(), now: checkedAt)

        let fresh = await cache.states(for: configuration(), maxAge: 300, now: checkedAt.addingTimeInterval(299))
        #expect(fresh == states)
        let expired = await cache.states(for: configuration(), maxAge: 300, now: checkedAt.addingTimeInterval(301))
        #expect(expired == nil)
        let otherSettings = await cache.states(
            for: configuration(claudePath: "/usr/local/bin/claude"),
            maxAge: 300,
            now: checkedAt
        )
        #expect(otherSettings == nil)
    }

    /// The service consults the cache before probing, and a probe result is
    /// what fills it — so the second open of a task never re-runs the CLIs.
    @Test("Availability service answers from the cache before probing")
    func serviceAnswersFromCacheBeforeProbing() async {
        let cache = RuntimeReadinessStateCache()
        let service = RuntimeProviderAvailabilityService(
            readinessService: RuntimeReadinessService(
                runner: StubBinaryRunner(),
                detectExecutable: { _ in "" },
                isExecutable: { _ in false }
            )
        )

        let probed = await service.states(configuration: configuration(), cache: cache)
        #expect(probed.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
        #expect(await cache.states(for: configuration(), maxAge: 300) == probed)

        let remembered: [AgentRuntimeID: RuntimeReadinessState] = [.claudeCode: .ready]
        await cache.store(remembered, for: configuration())
        let served = await service.states(configuration: configuration(), cache: cache)
        #expect(served == remembered)

        let bypassed = await service.states(configuration: configuration(), cache: nil)
        #expect(bypassed == probed)
    }

    /// The default must stay uncached. A cache keyed only by configuration
    /// cannot tell two differently-probed services apart, so a shared default
    /// made one caller's verdict answer for another's — it broke
    /// `RuntimeReadinessServiceTests` the moment both ran in one process.
    @Test("Availability service does not cache unless the caller passes one")
    func serviceDoesNotCacheByDefault() async {
        let readyEverything = RuntimeProviderAvailabilityService(
            readinessService: RuntimeReadinessService(
                runner: StubBinaryRunner(),
                detectExecutable: { _ in "" },
                isExecutable: { _ in false }
            )
        )
        let first = await readyEverything.states(configuration: configuration())
        await RuntimeReadinessStateCache.shared.store([.claudeCode: .ready], for: configuration())
        let second = await readyEverything.states(configuration: configuration())
        #expect(second == first)
        #expect(second.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
        await RuntimeReadinessStateCache.shared.removeAll()
    }
}
