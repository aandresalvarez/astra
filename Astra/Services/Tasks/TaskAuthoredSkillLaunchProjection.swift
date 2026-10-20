import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Apply request-time environment references to unmanaged authored copies.
/// The queued policy already owns these facts; looking up the live skill's
/// namespace here would silently rotate an accepted request after submission.
@MainActor
enum TaskAuthoredSkillLaunchProjection {
    static func apply(_ snapshots: [SkillSnapshotConfig], to skills: [Skill], excluding overrides: Set<UUID>) {
        let saved = Dictionary(snapshots.compactMap { snapshot -> (UUID, SkillSnapshotConfig)? in
            guard let id = snapshot.id.flatMap(UUID.init(uuidString:)) else { return nil }
            return (id, snapshot)
        }, uniquingKeysWith: { first, _ in first })
        // PluginOverrideRecords already applied the accepted override state.
        // Migration clears those rows' origins, so provenance alone cannot
        // distinguish them from independent authored skills.
        for skill in skills where skill.modelContext == nil && skill.originPackageID == nil && !overrides.contains(skill.id) {
            guard let snapshot = saved[skill.id] else { continue }
            skill.credentialNamespaceID = snapshot.credentialNamespaceID
            skill.environmentKeys = snapshot.environmentKeys
            skill.environmentValues = snapshot.environmentValues
        }
    }
}
