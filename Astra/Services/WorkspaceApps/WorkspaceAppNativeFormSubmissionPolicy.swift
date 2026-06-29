struct WorkspaceAppNativeFormSubmission {
    var action: WorkspaceAppActionSpec
    var input: WorkspaceAppActionInput
}

enum WorkspaceAppNativeFormSubmissionPolicy {
    static func submission(
        for view: WorkspaceAppViewSpec,
        manifest: WorkspaceAppManifest,
        values: [String: WorkspaceAppStorageValue]
    ) -> WorkspaceAppNativeFormSubmission? {
        guard let submit = manifest.actions.first(where: {
            $0.type == "capability.write" && ($0.table == nil || $0.table == view.table)
        }) else {
            return nil
        }

        return WorkspaceAppNativeFormSubmission(
            action: submit,
            input: WorkspaceAppActionInput(table: view.table, record: values)
        )
    }
}
