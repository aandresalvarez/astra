import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A run that reached for a connector whose credentials the turn did not
/// unseal: Ask offers the connector in the dock, Auto allows it for the task
/// and says so, because Auto asks nothing.
@Suite("Brokered credential offers by level")
@MainActor
struct BrokeredCredentialLevelTests {
    @Test("Auto allows the connector for the task; Ask offers it")
    func autoAllowsAskOffers() throws {
        for level in [AgentPolicyLevel.autonomous, .review, .custom] {
            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            let context = container.mainContext
            let task = AgentTask(title: "Tickets", goal: "Summarize my week")
            let run = TaskRun(task: task)
            run.runtimeID = AgentRuntimeID.claudeCode.rawValue
            context.insert(task)
            context.insert(run)
            try context.save()

            let connectorID = UUID()
            let label = "connector:\(connectorID.uuidString):JIRA_API_TOKEN"
            let ledger = BrokeredCredentialApprovalLedger.shared
            ledger.record(
                .init(connectorID: connectorID, connectorName: "Jira", alias: "jira",
                      serviceType: "jira", credentialLabels: [label]),
                taskID: task.id,
                runID: run.id
            )

            BrokeredCredentialApprovalDiscovery.recordWithheldCredentialRequests(
                task: task,
                run: run,
                modelContext: context,
                policyLevel: level,
                runFinishedCleanly: true,
                ledger: ledger
            )

            let granted = TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .claudeCode)
            let notice = task.events.first { $0.payload.hasPrefix("Auto allowed Jira") }?.payload
            if level == .autonomous {
                #expect(granted.contains(.credential(label: label)), "Auto grants")
                #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task), "Auto does not offer")
                #expect(notice == "Auto allowed Jira to use its saved credentials for this task. "
                    + "The agent can use it from the next message.")
            } else {
                #expect(granted.isEmpty, "\(level.rawValue) does not grant")
                #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task), "\(level.rawValue) offers")
                #expect(notice == nil)
            }
        }
    }

    /// An offer an Ask run left is the user's pending decision. Switching the
    /// task to Auto answers it — Auto allows the connector for the task — even
    /// when the next message does not name that connector.
    @Test("Switching to Auto grants a connector offer an Ask run left open")
    func switchingToAutoGrantsAPendingOffer() async throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Tickets", goal: "Summarize my week")
        let askRun = TaskRun(task: task)
        askRun.runtimeID = AgentRuntimeID.claudeCode.rawValue
        context.insert(task)
        context.insert(askRun)
        try context.save()
        let label = "connector:\(UUID().uuidString):JIRA_API_TOKEN"
        let ledger = BrokeredCredentialApprovalLedger.shared
        ledger.record(
            .init(connectorID: UUID(), connectorName: "Jira", alias: "jira", serviceType: "jira", credentialLabels: [label]),
            taskID: task.id,
            runID: askRun.id
        )
        BrokeredCredentialApprovalDiscovery.recordWithheldCredentialRequests(
            task: task, run: askRun, modelContext: context, policyLevel: .review, runFinishedCleanly: true, ledger: ledger
        )
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))

        let autoRun = TaskRun(task: task)
        autoRun.runtimeID = AgentRuntimeID.claudeCode.rawValue
        context.insert(autoRun)
        _ = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task, run: autoRun, modelContext: context, phase: .run,
            contextText: "Now the calendar", permissionPolicy: .autonomous, secretStore: MockSecretStore()
        )

        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .claudeCode).contains(.credential(label: label)))
        #expect(task.events.contains { $0.payload == "Auto allowed Jira to use its saved credentials for this task." })
    }

    /// A cancelled or failed run's reach is not consent for a retry to hold the
    /// credentials, and a grant that could not be saved is not a grant: both
    /// become the offer Ask would make, with nothing left behind.
    @Test("Auto offers instead of granting after an unfinished run or an unsaved grant")
    func autoOffersWhenItCannotGrant() throws {
        for (finished, saves) in [(false, true), (true, false)] {
            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            let context = container.mainContext
            let task = AgentTask(title: "Tickets", goal: "Summarize my week")
            let run = TaskRun(task: task)
            run.runtimeID = AgentRuntimeID.claudeCode.rawValue
            context.insert(task)
            context.insert(run)
            try context.save()
            let connectorID = UUID()
            let label = "connector:\(connectorID.uuidString):JIRA_API_TOKEN"
            let ledger = BrokeredCredentialApprovalLedger.shared
            ledger.record(
                .init(connectorID: connectorID, connectorName: "Jira", alias: "jira",
                      serviceType: "jira", credentialLabels: [label]),
                taskID: task.id,
                runID: run.id
            )
            var saveAttempts = 0

            BrokeredCredentialApprovalDiscovery.recordWithheldCredentialRequests(
                task: task,
                run: run,
                modelContext: context,
                policyLevel: .autonomous,
                runFinishedCleanly: finished,
                ledger: ledger,
                persistAutoGrant: { _, _ in
                    saveAttempts += 1
                    return saves
                }
            )

            let scenario = finished ? "unsaved grant" : "unfinished run"
            #expect(saveAttempts == (finished ? 1 : 0), "\(scenario)")
            #expect(TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .claudeCode).isEmpty, "\(scenario)")
            #expect(!task.events.contains { $0.payload.hasPrefix("Auto allowed Jira") }, "\(scenario)")
            #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task), "\(scenario) offers")
        }
    }
}
