import Foundation
import ASTRACore

/// Per-runtime support facts for capability resource kinds that not every
/// agent runtime can consume. Drives the honesty badges in the catalog so a
/// declared MCP server is never presented as universally available.
enum CapabilityRuntimeSupportPresentation {

    static func allRuntimeDescriptors() -> [AgentRuntimeDescriptor] {
        AgentRuntimeAdapterRegistry.allAdapters.map(\.descriptor)
    }

    /// Runtimes that materialize capability-package MCP servers at launch.
    static func mcpSupportingRuntimes(
        descriptors: [AgentRuntimeDescriptor]
    ) -> [AgentRuntimeDescriptor] {
        descriptors.filter(\.supportsMCPServers)
    }

    /// One-line subtitle for the catalog's MCP section, e.g.
    /// "Delivered on Claude Code runs; other runtimes skip these servers."
    static func mcpSupportSubtitle(
        descriptors: [AgentRuntimeDescriptor] = allRuntimeDescriptors()
    ) -> String {
        let supporting = mcpSupportingRuntimes(descriptors: descriptors)
        guard !supporting.isEmpty else {
            return "Not delivered to any installed runtime yet"
        }
        let names = supporting.map(\.displayName).sorted().joined(separator: ", ")
        if supporting.count == descriptors.count {
            return "Delivered on all runtimes"
        }
        return "Delivered on \(names) runs; other runtimes skip these servers"
    }
}
