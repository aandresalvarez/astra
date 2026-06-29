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
        let supportingRuntimeIDs = Set(MCPRuntimeSupportMatrix.profiles(for: descriptors)
            .filter(\.supportsDelivery)
            .map(\.runtimeID))
        return descriptors.filter { supportingRuntimeIDs.contains($0.id) }
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

    static func mcpSupportSubtitle(
        for package: PluginPackage,
        descriptors: [AgentRuntimeDescriptor] = allRuntimeDescriptors()
    ) -> String {
        mcpSupportSubtitle(
            for: package.mcpServers,
            descriptors: descriptors
        )
    }

    static func mcpSupportSubtitle(
        for servers: [PluginMCPServer],
        descriptors: [AgentRuntimeDescriptor] = allRuntimeDescriptors()
    ) -> String {
        guard !servers.isEmpty else {
            return "No MCP servers declared"
        }
        let profiles = MCPRuntimeSupportMatrix.profiles(for: descriptors)
        let support = profiles.reduce(into: (full: [AgentRuntimeID](), partial: [AgentRuntimeID]())) { result, profile in
            let deliveredCount = servers.filter { server in
                MCPRuntimeDeliveryPlanner.plan(server: server, profiles: [profile]).first?.compatibility == .compatible
            }.count
            if deliveredCount == servers.count {
                result.full.append(profile.runtimeID)
            } else if deliveredCount > 0 {
                result.partial.append(profile.runtimeID)
            }
        }
        let full = descriptors.filter { support.full.contains($0.id) }
        let partial = descriptors.filter { support.partial.contains($0.id) }
        guard !full.isEmpty || !partial.isEmpty else {
            return "Not delivered to any installed runtime yet"
        }
        if full.count == descriptors.count {
            return "Delivered on all runtimes"
        }
        let fullNames = full.map(\.displayName).sorted().joined(separator: ", ")
        let partialNames = partial.map(\.displayName).sorted().joined(separator: ", ")
        if full.isEmpty {
            return "Partially delivered on \(partialNames) runs; some servers are skipped"
        }
        if partial.isEmpty {
            return "Delivered on \(fullNames) runs; other runtimes skip these servers"
        }
        return "Delivered on \(fullNames) runs; partially delivered on \(partialNames) runs"
    }
}
