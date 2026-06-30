import Foundation

enum WorkspaceAppTestRepairRequestBuilder {
    static func prompt(
        for result: WorkspaceAppCheckResult,
        manifest: WorkspaceAppManifest
    ) -> String {
        let appName = manifest.app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = appName.isEmpty ? "this app" : "'\(appName)'"
        return """
        Fix this App Studio test failure in \(target).

        Failing check: \(result.label)
        Failure detail: \(result.detail)

        Make the visible app behavior and manifest actions agree, then keep the app valid and publishable.

        ASTRA appStorage contracts to preserve:
        - appStorage.query reads stored rows.
        - appStorage.insert adds one row.
        - appStorage.update changes an existing row by primary key.
        - appStorage.delete hard-deletes a primary-key row; deleted rows disappear from later query/list results. Do not invent an is_deleted soft-delete expectation unless the app intentionally implements archive through appStorage.update.
        - Storage-backed HTML can call astra.query, astra.insert, and astra.update. A trash/delete control in HTML must use a supported archive/update flow, or the app must expose deletion through a governed native action instead of a dead HTML button.

        After the edit, the Test app checks should pass for this failure.
        """
    }
}
