import Foundation
import ASTRACore

enum RuntimeModelRefreshSignature {
    static func make(
        runtime: AgentRuntimeID,
        executablePath: String,
        providerSettings: AgentRuntimeProviderSettings,
        claudeProviderRaw: String,
        claudeVertexOpusModel: String,
        claudeVertexSonnetModel: String,
        claudeVertexHaikuModel: String
    ) -> String {
        [
            runtime.rawValue,
            executablePath,
            providerSettings.homeDirectory(for: runtime),
            runtime == .claudeCode ? claudeProviderRaw : "",
            runtime == .claudeCode ? claudeVertexOpusModel : "",
            runtime == .claudeCode ? claudeVertexSonnetModel : "",
            runtime == .claudeCode ? claudeVertexHaikuModel : ""
        ].joined(separator: "|")
    }
}
