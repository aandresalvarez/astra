import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

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
        let fixture = try makeExecutable(#"""
        IFS= read -r request
        case "$request" in *'"method":"initialize"'*) ;; *) exit 11;; esac
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r request
        case "$request" in *'"method":"initialized"'*) ;; *) exit 12;; esac
        IFS= read -r request
        case "$request" in *'"method":"model/list"'*) ;; *) exit 13;; esac
        printf '%s\n' '{"method":"notification"}' '{"id":2,"result":{"data":[{"model":"first"}],"nextCursor":"page-two"}}'
        IFS= read -r request
        case "$request" in *'"cursor":"page-two"'*) ;; *) exit 14;; esac
        printf '%s' '{"id":3,"result":{"data":['
        printf '%s\n' '{"model":"second","isDefault":true}],"nextCursor":null}}'
        IFS= read -r request
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let models = try await CodexAppServerModelProbe(timeout: 2).models(executablePath: fixture.path, environment: [:])
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
        await #expect(throws: (any Error).self) {
            try await CodexAppServerModelProbe(timeout: 2).models(executablePath: fixture.path, environment: [:])
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
        await #expect(throws: CodexModelProbeError.self) {
            try await CodexAppServerModelProbe(timeout: 2).models(executablePath: fixture.path, environment: [:])
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
        let task = Task { try await CodexAppServerModelProbe(timeout: cancel ? 10 : 0.1).models(executablePath: fixture.path, environment: [:]) }
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
