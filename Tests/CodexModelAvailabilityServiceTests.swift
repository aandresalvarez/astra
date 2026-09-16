import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Budget for the tests whose subject is *what* the app-server conversation
/// does, not how fast a shell script and four pipe round trips complete on a
/// loaded machine. It is a hang breaker, not a latency assertion: a probe that
/// never writes a request, never reads a reply, or never reaps the child leaves
/// the fixture blocked in `read` forever, and something has to end that.
///
/// At 2 seconds it was a latency assertion, and it failed as one. Two
/// consecutive full `swift test` runs on 2026-09-10 reported `.timedOut` from
/// the pagination test after 14 s of wall clock, while the same test passed
/// five runs in a row in ~0.9 s under `--filter`. Nothing in the probe was
/// slow; spawning `/bin/sh` and getting its `read` scheduled against 6,600
/// other tests was, and a budget that small measures the machine rather than
/// the protocol. A genuine hang still fails these tests — just slowly.
///
/// Timeout *classification* is asserted separately, by `boundedLifetime`, which
/// points a deliberately short budget at a child that never answers. That stays
/// honest under the same load by construction: contention can only push the
/// child further past its deadline, never under it. Don't fold the two kinds of
/// budget back together.
private let hangBreakerTimeout: TimeInterval = 120

@Suite("Codex model discovery")
struct CodexModelAvailabilityServiceTests {
    @Test("New provider models and capabilities replace offline choices without rewriting explicit selections")
    func refreshCatalog() async throws {
        let name = "CodexModelDiscovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = try JSONDecoder().decode([CodexModelInfo].self, from: Data(#"""
        [
          {"model":"gpt-5.5"},
          {"model":"future-model","displayName":"Future model","isDefault":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"ultra","description":"Deep reasoning"}],"inputModalities":["text","image"]},
          {"model":"hidden-model","hidden":true},
          {"model":"future-model","displayName":"Duplicate"},
          {"model":" "}
        ]
        """#.utf8))
        let probe = StubCodexModelProbe(catalog: catalog)
        let service = CodexModelAvailabilityService(probe: probe, detectExecutable: { "/detected/codex" })
        let result = await service.refreshAndPersist(executablePath: " /configured/codex ", homeDirectory: "/test/codex-home", defaults: defaults)
        guard case .available(let details) = result else { Issue.record("Expected available models"); return }
        #expect(details.map(\.value) == ["future-model", "gpt-5.5"])
        #expect(details.first?.codex?.supportedReasoningEfforts?.first?.reasoningEffort == "ultra")
        #expect(await probe.path == "/configured/codex")
        #expect(await probe.home == "/test/codex-home")
        #expect(RuntimeModelAvailability.defaultModel(for: .codexCLI, defaults: defaults) == "future-model")
        #expect(RuntimeModelAvailability.normalizedModel("hidden-model", for: .codexCLI, defaults: defaults) == "hidden-model")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5.5", for: .codexCLI, defaults: defaults) == "gpt-5.5")
        let raw = try #require(defaults.string(forKey: AppStorageKeys.runtimeAvailableModelsKey(for: .codexCLI)))
        let snapshot = try JSONDecoder().decode(RuntimeModelAvailabilitySnapshot.self, from: Data(raw.utf8))
        #expect(snapshot.authority == .suggestions)
        #expect(snapshot.details?.first?.codex?.inputModalities == ["text", "image"])
        #expect(snapshot.details?.first?.displayName == "Future model")
        let cache = RuntimeModelAvailabilityCache(rawSnapshots: [.codexCLI: raw])
        #expect(RuntimeModelAvailability.modelForRuntimeSwitch(currentModel: "another-provider", to: .codexCLI, cache: cache) == "future-model")
        #expect(RuntimeModelAvailability.modelForRuntimeSwitch(currentModel: "gpt-5.5", to: .codexCLI, cache: cache) == "gpt-5.5")
    }

    @Test("Missing configured executable reports a readiness warning")
    func unavailableReadiness() async {
        let configuration = RuntimeReadinessConfiguration(
            runtime: .codexCLI,
            providerSettings: AgentRuntimeProviderSettings(executablePaths: [.codexCLI: "/nonexistent/astra-test-codex"]),
            claudeProvider: .anthropic, vertexProjectID: "", vertexRegion: "",
            vertexOpusModel: "", vertexSonnetModel: "", vertexHaikuModel: ""
        )
        let check = await CodexCLIRuntimeAdapter().modelAvailabilityCheck(configuration: configuration)
        #expect(check.state == .warning)
        #expect(check.remediation?.contains("No runnable Codex CLI") == true)
    }

    @Test("Failed or empty discovery retains last successful catalog")
    func retainsCache() async throws {
        let name = "CodexModelDiscovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        RuntimeModelAvailability.persistAvailableModels(["saved-model"], for: .codexCLI, defaults: defaults)
        let key = AppStorageKeys.runtimeAvailableModelsKey(for: .codexCLI)
        let original = defaults.string(forKey: key)
        for fail in [false, true] {
            let probe = StubCodexModelProbe(catalog: [], fail: fail)
            let result = await CodexModelAvailabilityService(probe: probe).refreshAndPersist(executablePath: "/codex", defaults: defaults)
            guard case .unavailable = result else { Issue.record("Expected discovery failure"); continue }
            #expect(defaults.string(forKey: key) == original)
        }
        // Old ASTRA versions saved their hard-coded list as authoritative.
        #expect(RuntimeModelAvailability.normalizedModel("future-model", for: .codexCLI, defaults: defaults) == "future-model")
    }

    @Test("App-server handshake waits for initialize and follows pagination")
    func realTransportPagination() async throws {
        // Each step is journalled only once the request that earns it has
        // matched, so the file is a record of protocol state and not of timing.
        let fixture = try makeExecutable(#"""
        journal="$0.requests"
        IFS= read -r request
        case "$request" in *'"method":"initialize"'*) ;; *) exit 11;; esac
        printf 'initialize\n' >> "$journal"
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r request
        case "$request" in *'"method":"initialized"'*) ;; *) exit 12;; esac
        printf 'initialized\n' >> "$journal"
        IFS= read -r request
        case "$request" in *'"method":"model/list"'*) ;; *) exit 13;; esac
        printf 'model-list\n' >> "$journal"
        printf '%s\n' '{"method":"notification"}' '{"id":2,"result":{"data":[{"model":"first"}],"nextCursor":"page-two"}}'
        IFS= read -r request
        case "$request" in *'"cursor":"page-two"'*) ;; *) exit 14;; esac
        printf 'page-two\n' >> "$journal"
        printf '%s' '{"id":3,"result":{"data":['
        printf '%s\n' '{"model":"second","isDefault":true}],"nextCursor":null}}'
        IFS= read -r request
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let journal = URL(fileURLWithPath: fixture.path + ".requests")
        let path = fixture.path
        let probe = Task {
            try await CodexAppServerModelProbe(timeout: hangBreakerTimeout)
                .models(executablePath: path, environment: [:])
        }
        defer { probe.cancel() }
        // The handshake is ordered, so a journalled step is also the evidence
        // that the step before it was answered. Waiting on the steps rather
        // than on the conversation as a whole is what keeps a slow spawn from
        // reading as a protocol failure, and it names the step that stalled
        // when one really does.
        for step in ["initialize", "initialized", "model-list", "page-two"] {
            try #require(await requestArrived(step, in: journal), "The fixture never received \(step)")
        }
        let models = try await probe.value
        #expect(models.map(\.model) == ["first", "second"])
        #expect(models.last?.isDefault == true)
    }

    @Test("Protocol failures do not produce partial catalogs", arguments: [
        #"{"id":2,"error":{"code":-32601,"message":"unsupported"}}"#,
        #"{"id":2,"result":{"data":"invalid"}}"#,
        "not-json"
    ])
    func protocolFailure(response: String) async throws {
        let fixture = try makeExecutable("""
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r request
        IFS= read -r request
        printf '%s\\n' '\(response)'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        do {
            let models = try await CodexAppServerModelProbe(timeout: hangBreakerTimeout)
                .models(executablePath: fixture.path, environment: [:])
            Issue.record("Expected a protocol failure, got \(models.map(\.model))")
        } catch {
            // `.timedOut` satisfies "it threw" while proving nothing about the
            // response, so the budget above is not allowed to answer for it.
            #expect(error as? CodexModelProbeError != .timedOut)
        }
    }

    @Test("Repeated pagination cursors fail instead of caching a partial list")
    func repeatedCursor() async throws {
        let fixture = try makeExecutable(#"""
        IFS= read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r request
        IFS= read -r request
        printf '%s\n' '{"id":2,"result":{"data":[{"model":"first"}],"nextCursor":"same"}}'
        IFS= read -r request
        printf '%s\n' '{"id":3,"result":{"data":[{"model":"second"}],"nextCursor":"same"}}'
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        // Naming the case matters for the same reason: a bare `CodexModelProbeError`
        // would also be satisfied by the deadline that is only here to break a hang.
        await #expect(throws: CodexModelProbeError.repeatedCursor) {
            try await CodexAppServerModelProbe(timeout: hangBreakerTimeout)
                .models(executablePath: fixture.path, environment: [:])
        }
    }

    @Test("Installed Codex exposes its catalog without starting a turn",
          .enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_MODEL_DISCOVERY_SMOKE"] == "1"))
    func liveCatalog() async throws {
        let models = try await CodexAppServerModelProbe().models(
            executablePath: CodexCLIRuntime.detectPath(), environment: RuntimeProcessEnvironment.enriched()
        )
        #expect(!models.isEmpty)
        #expect(models.contains { $0.isDefault == true })
        #expect(models.allSatisfy { !$0.model.isEmpty })
    }

    @Test("Hung app-server is stopped at the deadline or on cancellation", arguments: [false, true])
    func boundedLifetime(cancel: Bool) async throws {
        let fixture = try makeExecutable("IFS= read -r request\nIFS= read -r request\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        // The deadline case is the one place a short budget belongs: the child
        // never answers, so load can only push it further past 0.1 s. The
        // cancellation case asserts who wins, not how long winning took.
        let budget = cancel ? hangBreakerTimeout : 0.1
        let path = fixture.path
        let task = Task { try await CodexAppServerModelProbe(timeout: budget).models(executablePath: path, environment: [:]) }
        if cancel { task.cancel() }
        do {
            _ = try await task.value
            Issue.record("Expected the hung process to be stopped")
        } catch {
            if cancel {
                #expect(error is CancellationError)
            } else {
                #expect(error as? CodexModelProbeError == .timedOut)
            }
        }
    }

    /// Waits for a step the fixture journals only after the request for it has
    /// arrived and matched, so the wait ends on protocol state rather than on a
    /// guess about what a subprocess round trip costs today.
    ///
    /// Both bounds have to be exhausted before this gives up: the deadline
    /// stops a genuinely stuck handshake from hanging the suite, and the poll
    /// floor stops a starved one from being mistaken for it. A step that has
    /// already arrived returns on the first turn, so neither bound slows the
    /// happy path. Polling with `Task.sleep` rather than a blocking wait keeps
    /// the cooperative pool free for the probe's own queue.
    private func requestArrived(_ step: String, in journal: URL, timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        while true {
            let journalled = (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
            if journalled.contains(step + "\n") { return true }
            guard polls < 40 || Date() < deadline else { return false }
            polls += 1
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func makeExecutable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

private actor StubCodexModelProbe: CodexModelCatalogProbing {
    let catalog: [CodexModelInfo]
    let fail: Bool
    var path: String?
    var home: String?

    init(catalog: [CodexModelInfo], fail: Bool = false) {
        self.catalog = catalog
        self.fail = fail
    }

    func models(executablePath: String, environment: [String: String]) async throws -> [CodexModelInfo] {
        path = executablePath
        home = environment["CODEX_HOME"]
        if fail { throw CodexModelProbeError.timedOut }
        return catalog
    }
}
