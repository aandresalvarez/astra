import Foundation

/// Phase 1 of the Studio UX redesign: a plain-language identity for a draft app, so a builder
/// instantly knows WHAT they're building (the archetype), what it DOES (purpose + capabilities),
/// and how it's governed (permission in plain English) — instead of reading the raw manifest.
/// Pure + derived from the manifest, so the SwiftUI card is a thin renderer and this is unit-tested.
struct WorkspaceAppStudioIdentityPresentation: Equatable {
    var archetypeLabel: String        // the manifest's own archetype label, e.g. "Review Queue"
    var iconSystemName: String
    var name: String
    var purpose: String               // one plain-language line
    var capabilities: [String]        // "what you'll be able to do" bullets
    var permissionSummary: String     // plain English, not "draftOnly"
    var permissionIcon: String
    var isReadyToPublish: Bool
}

enum WorkspaceAppStudioIdentityBuilder {
    static func identity(
        for manifest: WorkspaceAppManifest,
        report: WorkspaceAppManifestValidationReport
    ) -> WorkspaceAppStudioIdentityPresentation {
        let label = manifest.app.archetypes
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Workspace app"
        let archetype = WorkspaceAppArchetype.from(label: label)
        let permission = permissionSummary(manifest)
        return WorkspaceAppStudioIdentityPresentation(
            archetypeLabel: label,
            iconSystemName: archetype?.iconSystemName ?? "square.grid.2x2",
            name: manifest.app.name,
            purpose: purpose(manifest: manifest, archetype: archetype),
            capabilities: capabilities(manifest),
            permissionSummary: permission.text,
            permissionIcon: permission.icon,
            isReadyToPublish: report.isValid
        )
    }

    static func purpose(manifest: WorkspaceAppManifest, archetype: WorkspaceAppArchetype?) -> String {
        let described = manifest.app.description.trimmingCharacters(in: .whitespacesAndNewlines)
        // The deterministic recipes share a boilerplate description; prefer the archetype's
        // plain tagline over it so the hero line is meaningful even on the offline path.
        let isBoilerplate = described.isEmpty
            || described.lowercased().contains("operational app surface generated")
        if !isBoilerplate { return described }
        return archetype?.tagline ?? "A custom workspace app."
    }

    /// Plain-language "what you'll be able to do", derived from the manifest's actual primitives.
    static func capabilities(_ manifest: WorkspaceAppManifest) -> [String] {
        let types = Set(manifest.actions.map(\.type))
        let hasForm = manifest.views.contains { $0.type == "form" && !$0.formFields.isEmpty }
        let widgets = manifest.views.flatMap(\.widgets)
        var capabilities: [String] = []

        if types.contains("appStorage.insert") || hasForm { capabilities.append("Add and edit records") }
        if types.contains("appStorage.delete") { capabilities.append("Remove records") }
        if widgets.contains(where: { $0.type == "chart" }) {
            capabilities.append("See your data as a chart")
        } else if widgets.contains(where: { $0.type == "metric" }) {
            capabilities.append("See summary metrics")
        }
        if types.contains("pipeline.run") || types.contains("loop.run") {
            capabilities.append("Run a multi-step workflow")
        }
        if types.contains("gate.humanApproval") || types.contains("gate.agentRecommendation") {
            capabilities.append("Approve steps before they run")
        }
        if types.contains("task.createAndRun") || types.contains("task.createDraft") || types.contains("task.fanOut") {
            capabilities.append("Hand work to an AI task")
        }
        if types.contains("capability.write") { capabilities.append("Write to a connected system") }
        if types.contains("artifact.export") { capabilities.append("Export to a file") }
        if capabilities.isEmpty { capabilities.append("View stored data") }
        return capabilities
    }

    static func permissionSummary(_ manifest: WorkspaceAppManifest) -> (text: String, icon: String) {
        let writesExternal = !manifest.permissions.externalWrites.isEmpty
            || manifest.actions.contains { $0.type == "capability.write" }
        switch manifest.permissions.defaultMode {
        case .readOnly:
            return ("Read-only — never changes anything", "eye")
        case .draftOnly:
            return ("Stays on your machine — no external systems", "lock")
        case .approvalRequired:
            return (writesExternal ? "Asks before writing to external systems" : "Asks before making changes", "hand.raised")
        case .preApproved:
            return (writesExternal ? "Can write to connected systems" : "Runs without prompting", "checkmark.shield")
        }
    }
}
