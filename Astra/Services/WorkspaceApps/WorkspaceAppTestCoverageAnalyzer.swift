import Foundation

enum WorkspaceAppTestCoverageAnalyzer {
    static func staticChecks(for manifest: WorkspaceAppManifest) -> [WorkspaceAppCheckResult] {
        var results: [WorkspaceAppCheckResult] = []
        if let deleteGap = storageHTMLDeleteAffordanceGap(in: manifest) {
            results.append(deleteGap)
        }
        return results
    }

    static func unsupportedScenarioFailure(
        scenario: String,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppScenarioCheckResult? {
        guard mentionsRemovalIntent(scenario), !hasExecutableRemovalPath(manifest) else { return nil }
        return WorkspaceAppScenarioCheckResult(
            check: nil,
            result: WorkspaceAppCheckResult(
                id: "scenario",
                label: scenario,
                status: .fail,
                detail: "This app has no executable delete/archive action. Add an appStorage.delete action, or add an appStorage.update action whose id or label makes the archive/remove flow explicit, then rerun this test."
            )
        )
    }

    static func hasExecutableRemovalPath(_ manifest: WorkspaceAppManifest) -> Bool {
        manifest.actions.contains { action in
            if action.type == "appStorage.delete" {
                return true
            }
            return action.type == "appStorage.update" && actionExpressesRemoval(action)
        }
    }

    private static func storageHTMLDeleteAffordanceGap(
        in manifest: WorkspaceAppManifest
    ) -> WorkspaceAppCheckResult? {
        guard let html = manifest.html,
              manifest.storage?.tables.isEmpty == false,
              htmlReferencesAstraBridge(html),
              containsDeleteAffordance(html) else {
            return nil
        }
        guard !hasExecutableRemovalPath(manifest) else { return nil }
        return WorkspaceAppCheckResult(
            id: "html-delete-affordance",
            label: "Delete UI coverage",
            status: .fail,
            detail: "The storage-backed HTML shows a delete/trash affordance, but the manifest does not expose a supported removal path. Back the UI with appStorage.delete or an explicit appStorage.update archive/remove action."
        )
    }

    private static func mentionsRemovalIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "delete", "deleted", "deleting",
            "remove", "removed", "removing",
            "trash", "trashed",
            "archive", "archived", "archiving"
        ].contains { lower.contains($0) }
    }

    private static func actionExpressesRemoval(_ action: WorkspaceAppActionSpec) -> Bool {
        [
            action.id,
            action.label,
            action.operation
        ]
        .compactMap { $0 }
        .contains { mentionsRemovalIntent($0) }
    }

    private static func htmlReferencesAstraBridge(_ html: String) -> Bool {
        html.lowercased().contains("astra.")
    }

    private static func containsDeleteAffordance(_ html: String) -> Bool {
        let lower = html.lowercased()
        return [
            "aria-label=\"delete",
            "aria-label='delete",
            "aria-label=\"remove",
            "aria-label='remove",
            "title=\"delete",
            "title='delete",
            "title=\"remove",
            "title='remove",
            ">delete<",
            ">remove<",
            "trash",
            "delete-note",
            "delete_note",
            "remove-note",
            "remove_note"
        ].contains { lower.contains($0) }
    }
}
