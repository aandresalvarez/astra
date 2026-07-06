import Foundation
import ASTRAModels

@MainActor
enum AgentRuntimeFailurePayload {
    /// Format a provider failure payload, folding in actionable install guidance
    /// when stderr looks like "command not found: X".
    static func enriched(prefix: String, rawError: String?, task: AgentTask) -> String {
        let raw = rawError ?? ""
        let knownPrereqs = PluginCatalog.builtInPackages.flatMap { $0.prerequisites }
        if let enrichment = ClaudeErrorEnricher.enrich(
            stderr: raw,
            knownPrerequisites: knownPrereqs
        ) {
            AppLogger.audit(.workerExited, category: "Worker", taskID: task.id, fields: [
                "enriched": "true",
                "missing_binary": enrichment.binary
            ], level: .warning)
            let tail = raw.isEmpty ? "" : "\n\nRaw error:\n\(raw)"
            return "\(prefix) \(enrichment.displayMessage)\(tail)"
        }
        return "\(prefix) \(raw)"
    }
}
