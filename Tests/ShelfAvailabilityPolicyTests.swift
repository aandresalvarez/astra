import Testing
@testable import ASTRA

@Suite("Shelf availability policy")
struct ShelfAvailabilityPolicyTests {
    @Test("Policy allows Plan only for an open task with plan content")
    func policyAllowsPlanOnlyForOpenTaskWithPlanContent() {
        let policy = ShelfAvailabilityPolicy()

        #expect(!policy.isToolbarAvailable(.plan, in: context(hasPlanContent: true)))
        #expect(!policy.canPresent(.plan, in: context(hasPlanContent: true)))
        #expect(!policy.isToolbarAvailable(.plan, in: context(hasOpenTaskThread: true)))
        #expect(!policy.canPresent(.plan, in: context(hasOpenTaskThread: true)))

        let openTaskWithPlan = context(hasOpenTaskThread: true, hasPlanContent: true)
        #expect(policy.isToolbarAvailable(.plan, in: openTaskWithPlan))
        #expect(policy.canPresent(.plan, in: openTaskWithPlan))
        #expect(policy.canRestoreRemembered(.plan, in: openTaskWithPlan))
    }

    @Test("Policy allows Browser for an open task by default")
    func policyAllowsBrowserForOpenTaskByDefault() {
        let policy = ShelfAvailabilityPolicy()

        #expect(!policy.isToolbarAvailable(.browser, in: context()))
        #expect(!policy.canPresent(.browser, in: context()))

        let openTask = context(hasOpenTaskThread: true)
        #expect(policy.isToolbarAvailable(.browser, in: openTask))
        #expect(policy.canPresent(.browser, in: openTask))
        #expect(policy.canRestoreRemembered(.browser, in: openTask))
    }

    @Test("Policy allows Query only when the task has a query affordance")
    func policyAllowsQueryOnlyWhenTaskHasQueryAffordance() {
        let policy = ShelfAvailabilityPolicy()

        #expect(!policy.isToolbarAvailable(.query, in: context(hasQueryShelfContent: true)))
        #expect(!policy.canPresent(.query, in: context(hasQueryShelfContent: true)))
        #expect(!policy.isToolbarAvailable(.query, in: context(hasOpenTaskThread: true)))
        #expect(!policy.canPresent(.query, in: context(hasOpenTaskThread: true)))

        let queryContent = context(hasOpenTaskThread: true, hasQueryShelfContent: true)
        #expect(policy.isToolbarAvailable(.query, in: queryContent))
        #expect(policy.canPresent(.query, in: queryContent))

        let activeQuery = context(hasOpenTaskThread: true, activeShelfID: .query)
        #expect(policy.isToolbarAvailable(.query, in: activeQuery))
        #expect(policy.canPresent(.query, in: activeQuery))
    }

    @Test("Policy rejects remembered shelf when disabled")
    func policyRejectsRememberedShelfWhenDisabled() {
        let policy = ShelfAvailabilityPolicy(disabledShelfIDs: [.browser])
        let openTask = context(hasOpenTaskThread: true)

        #expect(!policy.isToolbarAvailable(.browser, in: openTask))
        #expect(!policy.canPresent(.browser, in: openTask))
        #expect(!policy.canRestoreRemembered(.browser, in: openTask))
    }

    @Test("Policy preserves Files shelf for workspace context")
    func policyPreservesFilesShelfForWorkspaceContext() {
        let policy = ShelfAvailabilityPolicy()
        let workspaceContext = context(hasWorkspaceContext: true)

        #expect(policy.isToolbarAvailable(.files, in: workspaceContext))
        #expect(policy.canPresent(.files, in: workspaceContext))
        #expect(policy.canRestoreRemembered(.files, in: workspaceContext))

        let taskContext = context(hasOpenTaskThread: true)
        #expect(!policy.isToolbarAvailable(.files, in: taskContext))
        #expect(policy.canPresent(.files, in: taskContext))

        let activeFiles = context(activeShelfID: .files)
        #expect(policy.isToolbarAvailable(.files, in: activeFiles))
        #expect(!policy.canPresent(.files, in: activeFiles))
    }

    @Test("Policy preserves App Preview only during Studio")
    func policyPreservesAppPreviewOnlyDuringStudio() {
        let policy = ShelfAvailabilityPolicy()
        let nonStudio = context(
            hasOpenTaskThread: true,
            hasWorkspaceContext: true,
            hasPlanContent: true,
            hasFilesShelfContent: true,
            hasQueryShelfContent: true
        )

        #expect(!policy.isToolbarAvailable(.appPreview, in: nonStudio))
        #expect(!policy.canPresent(.appPreview, in: nonStudio))
        #expect(!policy.canRestoreRemembered(.appPreview, in: nonStudio))

        let studio = context(isComposingWorkspaceApp: true)
        #expect(policy.isToolbarAvailable(.appPreview, in: studio))
        #expect(policy.canPresent(.appPreview, in: studio))
        #expect(policy.canRestoreRemembered(.appPreview, in: studio))
    }

    private func context(
        hasOpenTaskThread: Bool = false,
        hasWorkspaceContext: Bool = false,
        hasPlanContent: Bool = false,
        hasFilesShelfContent: Bool = false,
        hasQueryShelfContent: Bool = false,
        isComposingWorkspaceApp: Bool = false,
        activeShelfID: ShelfID? = nil
    ) -> ShelfAvailabilityPolicy.Context {
        ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: hasOpenTaskThread,
            hasWorkspaceContext: hasWorkspaceContext,
            hasPlanContent: hasPlanContent,
            hasFilesShelfContent: hasFilesShelfContent,
            hasQueryShelfContent: hasQueryShelfContent,
            isComposingWorkspaceApp: isComposingWorkspaceApp,
            activeShelfID: activeShelfID
        )
    }
}
