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
}
