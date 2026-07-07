import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace App Automation Scheduler")
struct WorkspaceAppAutomationSchedulerTests {
    @Test("scheduler returns due enabled automations in scheduled order")
    func schedulerReturnsDueEnabledAutomationsInScheduledOrder() {
        let now = Date(timeIntervalSince1970: 1_000)
        let appID = UUID()
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "pipeline", name: "Pipeline"),
            automations: [
                WorkspaceAppAutomationSpec(
                    id: "late",
                    type: "schedule",
                    action: "refresh",
                    scheduleType: "interval",
                    intervalSeconds: 300
                ),
                WorkspaceAppAutomationSpec(
                    id: "early",
                    type: "schedule",
                    action: "refresh",
                    scheduleType: "interval",
                    intervalSeconds: 300
                ),
                WorkspaceAppAutomationSpec(
                    id: "disabled",
                    type: "schedule",
                    action: "refresh",
                    scheduleType: "interval",
                    intervalSeconds: 300
                )
            ]
        )
        let states = [
            WorkspaceAppAutomationState(
                workspaceID: UUID(),
                appID: appID,
                appLogicalID: "pipeline",
                automationID: "late",
                automationType: "schedule",
                actionID: "refresh",
                isEnabled: true,
                status: .enabled,
                nextRunAt: Date(timeIntervalSince1970: 900)
            ),
            WorkspaceAppAutomationState(
                workspaceID: UUID(),
                appID: appID,
                appLogicalID: "pipeline",
                automationID: "early",
                automationType: "schedule",
                actionID: "refresh",
                isEnabled: true,
                status: .enabled,
                nextRunAt: Date(timeIntervalSince1970: 800)
            ),
            WorkspaceAppAutomationState(
                workspaceID: UUID(),
                appID: appID,
                appLogicalID: "pipeline",
                automationID: "disabled",
                automationType: "schedule",
                actionID: "refresh",
                isEnabled: false,
                status: .disabled,
                nextRunAt: Date(timeIntervalSince1970: 700)
            )
        ]

        let due = WorkspaceAppAutomationScheduler().dueAutomations(
            manifest: manifest,
            states: states,
            now: now
        )

        #expect(due == [
            WorkspaceAppDueAutomation(
                automationID: "early",
                actionID: "refresh",
                scheduledAt: Date(timeIntervalSince1970: 800)
            ),
            WorkspaceAppDueAutomation(
                automationID: "late",
                actionID: "refresh",
                scheduledAt: Date(timeIntervalSince1970: 900)
            )
        ])
    }

    @Test("scheduler advances interval automation after run completion")
    func schedulerAdvancesIntervalAutomationAfterRunCompletion() {
        let completedAt = Date(timeIntervalSince1970: 2_000)
        let state = WorkspaceAppAutomationState(
            workspaceID: UUID(),
            appID: UUID(),
            appLogicalID: "pipeline",
            automationID: "refresh",
            automationType: "schedule",
            actionID: "refresh",
            isEnabled: true,
            status: .enabled
        )
        let spec = WorkspaceAppAutomationSpec(
            id: "refresh",
            type: "schedule",
            action: "refresh",
            scheduleType: "interval",
            intervalSeconds: 600
        )

        WorkspaceAppAutomationScheduler().markRunCompleted(
            automation: state,
            spec: spec,
            completedAt: completedAt
        )

        #expect(state.lastRunAt == completedAt)
        #expect(state.nextRunAt == Date(timeIntervalSince1970: 2_600))
        #expect(state.status == .enabled)
    }
}
