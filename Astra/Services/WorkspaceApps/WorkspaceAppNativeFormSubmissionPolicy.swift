import Foundation
import ASTRAModels

struct WorkspaceAppNativeFormSubmission {
    var action: WorkspaceAppActionSpec
    var input: WorkspaceAppActionInput
    var requiresExplicitApproval: Bool
    var approvalPresentation: WorkspaceAppNativeFormApprovalPresentation?
}

struct WorkspaceAppNativeFormApprovalPresentation: Equatable {
    var title: String
    var prompt: String
    var confirmLabel: String
}

enum WorkspaceAppNativeFormSubmissionPolicy {
    static func submission(
        for view: WorkspaceAppViewSpec,
        manifest: WorkspaceAppManifest,
        values: [String: WorkspaceAppStorageValue],
        actionID: String? = nil
    ) -> WorkspaceAppNativeFormSubmission? {
        let candidates = manifest.actions.filter { isFormWriteAction($0, for: view) }
        if let actionID {
            guard let selected = candidates.first(where: { $0.id == actionID }) else {
                return nil
            }
            return formSubmission(action: selected, view: view, manifest: manifest, values: values)
        }
        guard let submit = candidates.first(where: isSubmitCreateAction) ?? candidates.first else {
            return nil
        }
        return formSubmission(action: submit, view: view, manifest: manifest, values: values)
    }

    private static func formSubmission(
        action submit: WorkspaceAppActionSpec,
        view: WorkspaceAppViewSpec,
        manifest: WorkspaceAppManifest,
        values: [String: WorkspaceAppStorageValue]
    ) -> WorkspaceAppNativeFormSubmission {
        let presentation = approvalPresentation(for: submit, manifest: manifest)

        return WorkspaceAppNativeFormSubmission(
            action: submit,
            input: WorkspaceAppActionInput(
                table: view.table,
                record: values
            ),
            requiresExplicitApproval: presentation != nil,
            approvalPresentation: presentation
        )
    }

    private static func isFormWriteAction(_ action: WorkspaceAppActionSpec, for view: WorkspaceAppViewSpec) -> Bool {
        action.type == "capability.write" && (action.table == nil || action.table == view.table)
    }

    private static func isSubmitCreateAction(_ action: WorkspaceAppActionSpec) -> Bool {
        action.operation == "submitCreate"
    }

    private static func approvalPresentation(
        for action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppNativeFormApprovalPresentation? {
        guard action.agentRequiresApproval || manifest.permissions.defaultMode == .approvalRequired else {
            return nil
        }
        let title = action.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? action.label ?? "Confirm submission"
            : "Confirm submission"
        let prompt = action.approvalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? action.approvalPrompt ?? "Review and approve this submission before it writes to the external system."
            : "Review and approve this submission before it writes to the external system."
        return WorkspaceAppNativeFormApprovalPresentation(
            title: title,
            prompt: prompt,
            confirmLabel: positiveApprovalDecision(from: action.approvalDecisions) ?? "Approve"
        )
    }

    private static func positiveApprovalDecision(from decisions: [String]) -> String? {
        decisions.first { decision in
            let normalized = decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && !["cancel", "reject", "deny", "decline", "no"].contains(normalized)
        }
    }
}
