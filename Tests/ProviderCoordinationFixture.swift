import Foundation
import ASTRACore
@testable import ASTRA

/// Discarding task data never removes protected coordination receipts.
struct ProviderCoordinationFixture {
    let data: URL
    let coordination: URL

    init() throws {
        let run = try ProviderSharedStateNamespace.resolve()
        _ = try ProviderSharedStateDirectory(run)
        let id = UUID()
        let physical = run.appendingPathComponent("fixtures").appendingPathComponent(id.uuidString)
        _ = try ProviderSharedStateDirectory(physical)
        // Workspace and artifact APIs exchange Foundation's standard URL
        // spelling. The provider gate independently verifies physical identity.
        data = physical.standardizedFileURL
        coordination = ProviderSharedStateNamespace.coordinationRoot(in: run, fixtureID: id)
    }

    static func liveAntigravityHome(_ path: String? = ProcessInfo.processInfo.environment["REAL_PROVIDER_ANTIGRAVITY_HOME"]) throws -> String {
        let run = try ProviderSharedStateNamespace.resolve()
        let prefix = try ProviderSharedStateIdentity.canonicalPath(run.appendingPathComponent("fixtures").path) + "/"
        if let path, let home = try? ProviderSharedStateIdentity.canonicalPath(path), home.hasPrefix(prefix),
           let id = home.dropFirst(prefix.count).split(separator: "/").first, UUID(uuidString: String(id)) != nil {
            let settings = AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home)
            let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: settings)
            if key.filePath?.hasPrefix(prefix + String(id) + "/") == true,
               (try? ProviderSharedStateNamespace.resolve(key: key)) != nil { return home }
        }
        throw LiveProviderReadiness.Failure(runtimeID: .antigravityCLI,
            message: "Set REAL_PROVIDER_ANTIGRAVITY_HOME to an authenticated QA profile inside \(run.path)/fixtures/<fixture-UUID>/ for this invocation.")
    }
}
