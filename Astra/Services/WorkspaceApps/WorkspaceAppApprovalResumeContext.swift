import Foundation
import SwiftData

enum WorkspaceAppApprovalResumeContext {
    static func pendingBoundRows(
        for run: WorkspaceAppRun,
        pipelineID: String,
        gateID: String,
        stepIndex: Int,
        modelContext: ModelContext
    ) -> [[String: WorkspaceAppStorageValue]] {
        let events = ((try? modelContext.fetch(FetchDescriptor<WorkspaceAppRunEvent>())) ?? [])
            .filter { $0.runID == run.id && $0.type == "workspaceApp.run.awaitingApproval" }
            .sorted { $0.timestamp > $1.timestamp }

        for event in events {
            guard let payload = eventPayload(from: event.payload),
                  payloadText(payload["pipelineID"]) == pipelineID,
                  payloadText(payload["gateID"]) == gateID else {
                continue
            }
            if let eventStepIndex = payloadInteger(payload["stepIndex"]),
               eventStepIndex != stepIndex {
                continue
            }
            guard let rowsJSON = payloadText(payload["boundRowsJSON"]) else {
                continue
            }
            return boundRows(fromPayloadString: rowsJSON)
        }
        return []
    }

    static func boundRowsPayloadString(_ rows: [[String: WorkspaceAppStorageValue]]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rows),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func boundRows(fromPayloadString payload: String) -> [[String: WorkspaceAppStorageValue]] {
        guard let data = payload.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String: WorkspaceAppStorageValue]].self, from: data) else {
            return []
        }
        return rows
    }

    private static func eventPayload(from payload: String) -> [String: WorkspaceAppStorageValue]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: WorkspaceAppStorageValue].self, from: data)
    }

    private static func payloadText(_ value: WorkspaceAppStorageValue?) -> String? {
        guard case .text(let text) = value else { return nil }
        return text
    }

    private static func payloadInteger(_ value: WorkspaceAppStorageValue?) -> Int? {
        guard case .integer(let integer) = value else { return nil }
        return Int(integer)
    }
}
