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
        guard mentionsDeleteIntent(scenario), !hasExecutableDeleteAction(manifest) else { return nil }
        return WorkspaceAppScenarioCheckResult(
            check: nil,
            result: WorkspaceAppCheckResult(
                id: "scenario",
                label: scenario,
                status: .fail,
                detail: "This app has no executable delete action. Add an appStorage.delete action, or implement archive/removal through an appStorage.update flow, then rerun this test."
            )
        )
    }

    static func hasExecutableDeleteAction(_ manifest: WorkspaceAppManifest) -> Bool {
        manifest.actions.contains { $0.type == "appStorage.delete" }
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
        return WorkspaceAppCheckResult(
            id: "html-delete-affordance",
            label: "Delete UI coverage",
            status: .fail,
            detail: "The storage-backed HTML shows a delete/trash affordance, but ASTRA's HTML bridge exposes query, insert, and update only. Back the UI with a supported archive/update flow or move deletion into a governed native action."
        )
    }

    private static func mentionsDeleteIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "delete", "deleted", "deleting",
            "remove", "removed", "removing",
            "trash", "trashed"
        ].contains { lower.contains($0) }
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
