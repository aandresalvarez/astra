import CryptoKit
import Foundation
import os
import ASTRACore

/// The digest an activation records for the definition it accepted
/// (`PluginActivation.recordedDigest`): what runs, never where the copy came
/// from.
///
/// `CapabilityApprovalDigest` also covers a copy's source and its clamped
/// governance, so two copies of one definition (the bundled built-in and the
/// library's copy of it, or one plugin installed from two places) differ in
/// it. This one covers only what a run gets from the definition: its
/// identity and version, the components it projects or launches, and what
/// gates enabling it. A definition replaced under the same version and
/// components (an edited command, behavior or connector) differs in it, so
/// the activation awaits Add again (`PluginRuntimeProjection.awaitsUpdate`).
///
/// It is prefixed, so a digest recorded before it (an approval digest) is
/// told apart: `matches` cannot judge one, and the version-and-components
/// rule alone applies to it until the next Add records a content digest.
enum PluginDefinitionDigest {
    static let prefix = "content-v1:"

    /// Executable checks and remediation, excluding badge labels.
    private struct PrerequisiteContract: Encodable, Equatable, Sendable {
        let probeID: String
        let installURL: URL?
        let installHint: String
        let authHint: String?

        init(_ prerequisite: CLIPrerequisite) {
            probeID = prerequisite.id
            installURL = prerequisite.installURL
            installHint = prerequisite.installHint
            authHint = prerequisite.authHint
        }
    }

    /// What a run gets from a definition, excluding presentation, source and governance.
    private struct Content: Encodable, Equatable, Sendable {
        let id: String
        let version: String
        let minAppVersion: String?
        let skills: [PluginSkill]
        let connectors: [PluginConnector]
        let localTools: [PluginLocalTool]
        let mcpServers: [PluginMCPServer]
        let templates: [PluginTemplate]
        let setupRequirements: [PluginSetupRequirement]
        let browserAdapters: [String]
        let requires: [String]?
        let conflicts: [String]?
        // Omitted when empty, preserving existing digests without probes.
        let prerequisites: [PrerequisiteContract]?

        init(_ package: PluginPackage) {
            id = package.id
            version = package.version
            minAppVersion = package.minAppVersion
            skills = package.skills
            connectors = package.connectors
            localTools = package.localTools
            mcpServers = package.mcpServers
            templates = package.templates
            setupRequirements = package.setupRequirements
            browserAdapters = package.browserAdapters
            requires = package.requires
            conflicts = package.conflicts
            prerequisites = package.prerequisites.isEmpty ? nil : package.prerequisites.map(PrerequisiteContract.init)
        }
    }

    /// The last digest computed per plugin, reused while its content is
    /// equal: the runtime asks on every projection. Keyed by content, so it
    /// can never answer for another definition.
    private static let memo = OSAllocatedUnfairLock<[String: (content: Content, digest: String)]>(initialState: [:])

    static func content(of package: PluginPackage) -> String {
        let content = Content(package)
        if let cached = memo.withLock({ $0[package.id] }), cached.content == content { return cached.digest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain values cannot fail; an empty digest would match nothing.
        guard let data = try? encoder.encode(content) else { return "" }
        let digest = prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        memo.withLock { $0[package.id] = (content, digest) }
        return digest
    }

    static func isContentDigest(_ recorded: String) -> Bool {
        recorded.hasPrefix(prefix)
    }

    /// Whether `recorded` is `package`'s content digest; nil for one
    /// recorded before content digests (or none), which this can't judge.
    static func matches(_ recorded: String, _ package: PluginPackage) -> Bool? {
        guard isContentDigest(recorded) else { return nil }
        return recorded == content(of: package)
    }
}
