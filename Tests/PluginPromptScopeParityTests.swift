import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// R1 moves plugin skills and tools from materialized rows to a projection of
/// the workspace's activation. The prompt a task sees for every built-in must
/// not change: `PluginPromptScopeParityGolden` was recorded from the pre-R1
/// installer and resolver (materialized global rows matched by name and
/// service), and this test rebuilds each scope from a fresh Add and compares.
///
/// Re-record only for an intended change: `ASTRA_RECORD_PROMPT_SCOPE_PARITY=1
/// swift test --filter PluginPromptScopeParityTests` rewrites the golden file.
@Suite("Plugin prompt scope parity")
@MainActor
struct PluginPromptScopeParityTests {
    @Test("Every built-in's prompt scope after Add matches the pre-R1 scope")
    func builtInPromptScopesMatchGolden() throws {
        var scopes: [String: ScopeSummary] = [:]
        for package in PluginCatalog.builtInPackages.sorted(by: { $0.id < $1.id }) {
            do {
                scopes[package.id] = try scopeSummary(afterAdding: package)
            } catch CapabilityInstaller.InstallationError.blocked {
                // Hidden from this user by catalog policy; nothing to compare.
                continue
            }
        }
        #expect(scopes.count >= 8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recorded = String(decoding: try encoder.encode(scopes), as: UTF8.self)
        if ProcessInfo.processInfo.environment["ASTRA_RECORD_PROMPT_SCOPE_PARITY"] == "1" {
            let golden = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("PluginPromptScopeParityGolden.swift")
            let source = """
            // Recorded by PluginPromptScopeParityTests; do not edit by hand.
            enum PluginPromptScopeParityGolden {
                static let json = #\"\"\"
            \(recorded)
            \"\"\"#
            }

            """
            try source.write(to: golden, atomically: true, encoding: .utf8)
            return
        }

        let golden = try JSONDecoder().decode(
            [String: ScopeSummary].self,
            from: Data(PluginPromptScopeParityGolden.json.utf8)
        )
        #expect(Set(golden.keys) == Set(scopes.keys))
        for (id, expected) in golden {
            #expect(scopes[id] == expected, "\(id) prompt scope changed")
        }
    }

    // MARK: - Fixture

    struct ScopeSummary: Codable, Equatable {
        var behaviorSkills: [String]
        var behaviorInstructionsDigest: [String]
        var connectors: [String]
        var localTools: [String]
        var reachableConnectors: [String]
        var reachableLocalTools: [String]
        var enabledPackageIDs: [String]
        var reachablePackageIDs: [String]
        var enabledBrowserAdapters: [String]
        var skillEnvironmentKeys: [String]
        var hostControlRoutesGitHub: Bool
    }

    private func scopeSummary(afterAdding package: PluginPackage) throws -> ScopeSummary {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(container)
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Parity", primaryPath: workspaceFolder.path)
        context.insert(workspace)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = CapabilityInstaller(library: CapabilityLibrary(directory: root))
        _ = try installer.install(package, into: workspace, modelContext: context, announceCatalogMutation: false)

        // R1: Add stores no row for a plugin's skills or tools, and every
        // connector component gets an account bound to the activation.
        #expect(try context.fetch(FetchDescriptor<Skill>()).isEmpty, "\(package.id) stored a skill row")
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).isEmpty, "\(package.id) stored a tool row")
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        #expect(activation.bindings.count == package.connectors.count)
        #expect(!activation.recordedDigest.isEmpty)

        let task = AgentTask(
            title: package.name,
            goal: ([package.name] + package.skills.map(\.name) + package.connectors.map(\.name)).joined(separator: " "),
            workspace: workspace
        )
        context.insert(task)
        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: task.goal)
        return ScopeSummary(
            behaviorSkills: scope.behaviorSkills.map(\.name).sorted(),
            behaviorInstructionsDigest: scope.behaviorSkills
                .map { "\($0.name):\($0.behaviorInstructions.count):\($0.allowedTools.joined(separator: ","))" }
                .sorted(),
            connectors: scope.connectors.map { "\($0.name)|\($0.serviceType)|\($0.baseURL)" }.sorted(),
            localTools: scope.localTools.map { "\($0.name)|\($0.command)|\($0.arguments)" }.sorted(),
            reachableConnectors: scope.reachableConnectors.map(\.name).sorted(),
            reachableLocalTools: scope.reachableLocalTools.map(\.name).sorted(),
            enabledPackageIDs: scope.enabledPackageIDs.sorted(),
            reachablePackageIDs: scope.reachablePackageIDs.sorted(),
            enabledBrowserAdapters: scope.enabledBrowserAdapters.sorted(),
            skillEnvironmentKeys: scope.behaviorSkills.flatMap(\.environmentKeys).sorted(),
            hostControlRoutesGitHub: scope.behaviorSkills.contains { $0.originPackageID == "github-workflow" }
        )
    }

    /// SwiftData containers stay alive for the test binary's lifetime: a
    /// released container under a still-referenced model traps later.
    private static var retained: [ModelContainer] = []
}
