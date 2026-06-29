import Foundation

struct WorkspaceAppNativeFormSubmission {
    var action: WorkspaceAppActionSpec
    var input: WorkspaceAppActionInput
    var requiresExplicitApproval: Bool
}

enum WorkspaceAppNativeFormSubmissionPolicy {
    static func submission(
        for view: WorkspaceAppViewSpec,
        manifest: WorkspaceAppManifest,
        values: [String: WorkspaceAppStorageValue]
    ) -> WorkspaceAppNativeFormSubmission? {
        let candidates = manifest.actions.filter { isFormWriteAction($0, for: view) }
        guard let submit = candidates.first(where: isSubmitCreateAction) ?? candidates.first else {
            return nil
        }

        return WorkspaceAppNativeFormSubmission(
            action: submit,
            input: WorkspaceAppActionInput(
                table: view.table,
                record: values
            ),
            requiresExplicitApproval: declaresExplicitApproval(submit)
        )
    }

    private static func isFormWriteAction(_ action: WorkspaceAppActionSpec, for view: WorkspaceAppViewSpec) -> Bool {
        action.type == "capability.write" && (action.table == nil || action.table == view.table)
    }

    private static func isSubmitCreateAction(_ action: WorkspaceAppActionSpec) -> Bool {
        action.operation == "submitCreate"
    }

    private static func declaresExplicitApproval(_ action: WorkspaceAppActionSpec) -> Bool {
        action.approvalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            !action.approvalDecisions.isEmpty
    }
}
