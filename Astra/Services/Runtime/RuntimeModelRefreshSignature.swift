import Foundation
import ASTRACore

enum RuntimeModelRefreshSignature {
    static func make(
        runtime: AgentRuntimeID,
        executablePath: String,
        providerSettings: AgentRuntimeProviderSettings,
        claudeProviderRaw: String,
        claudeVertexProjectID: String = "",
        claudeVertexRegion: String = "",
        claudeVertexOpusModel: String,
        claudeVertexSonnetModel: String,
        claudeVertexHaikuModel: String
    ) -> String {
        [
            runtime.rawValue,
            executablePath,
            providerSettings.homeDirectory(for: runtime),
            runtime == .claudeCode ? claudeProviderRaw : "",
            // The availability check now rejects a Vertex route whose project or
            // region cannot name one, so both belong in the signature. Without
            // them, correcting a malformed project ID leaves the refresh
            // suppressed as a no-op and the stale "unavailable" on screen — the
            // user fixes the field and nothing happens.
            runtime == .claudeCode ? claudeVertexProjectID : "",
            runtime == .claudeCode ? claudeVertexRegion : "",
            runtime == .claudeCode ? claudeVertexOpusModel : "",
            runtime == .claudeCode ? claudeVertexSonnetModel : "",
            runtime == .claudeCode ? claudeVertexHaikuModel : ""
        ].joined(separator: "|")
    }
}
