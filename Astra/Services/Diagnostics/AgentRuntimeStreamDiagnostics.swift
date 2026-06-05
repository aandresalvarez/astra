import Foundation
import ASTRACore

@MainActor
enum AgentRuntimeStreamDiagnostics {
    static func logCopilotStreamTelemetry(
        snapshot: AgentRuntimeStreamTelemetrySnapshot,
        task: AgentTask,
        run: TaskRun,
        phase: String,
        exitCode: Int
    ) {
        var fields = snapshot.fields
        fields["runtime"] = AgentRuntimeID.copilotCLI.rawValue
        fields["phase"] = phase
        fields["exit_code"] = String(exitCode)
        fields["run_output_chars"] = String(run.output.count)
        fields["file_changes"] = String(run.fileChanges.count)

        let completedWithoutOutput = exitCode == 0
            && run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snapshot.completedEventCount == 0
        let parsedNoVisibleAnswer = snapshot.rawLineCount > 0
            && snapshot.textEventCount == 0
            && snapshot.completedEventCount == 0
        let streamLevel: LogLevel = (completedWithoutOutput || parsedNoVisibleAnswer || snapshot.unknownEventCount > 0)
            ? .warning
            : .info

        AppLogger.audit(.runtimeStreamSummary, category: "Worker", taskID: task.id, fields: fields, level: streamLevel)

        for sample in snapshot.unknownSamples {
            var fields = [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "phase": phase,
                "event_type": sample.type,
                "sample": sample.sample
            ]
            fields.merge(unknownEventShapeFields(raw: sample.sample)) { current, _ in current }
            AppLogger.audit(.runtimeUnknownEvent, category: "Worker", taskID: task.id, fields: fields, level: .warning)
        }

        if completedWithoutOutput {
            AppLogger.audit(.runtimeEmptyOutput, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "phase": phase,
                "exit_code": String(exitCode),
                "raw_lines": String(snapshot.rawLineCount),
                "parsed_events": String(snapshot.parsedEventCount),
                "text_events": String(snapshot.textEventCount),
                "completed_events": String(snapshot.completedEventCount),
                "unknown_events": String(snapshot.unknownEventCount)
            ], level: .warning)
        }
    }

    static func logStreamDebug(
        snapshot: AgentRuntimeStreamDebugSnapshot,
        runtime: AgentRuntimeID,
        task: AgentTask,
        run: TaskRun,
        phase: String,
        exitCode: Int
    ) {
        var fields = snapshot.fields
        fields["runtime"] = runtime.rawValue
        fields["phase"] = phase
        fields["exit_code"] = String(exitCode)
        fields["run_output_chars"] = String(run.output.count)
        fields["file_changes"] = String(run.fileChanges.count)

        AppLogger.audit(
            .runtimeStreamDebug,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: .debug,
            fieldMaxLength: 240
        )

        for (index, sample) in snapshot.rawSamples.enumerated() {
            AppLogger.audit(
                .runtimeStreamDebugSample,
                category: "Worker",
                taskID: task.id,
                fields: [
                    "runtime": runtime.rawValue,
                    "phase": phase,
                    "sample_kind": "raw_line",
                    "sample_index": String(index + 1),
                    "sample": sample
                ],
                level: .debug,
                fieldMaxLength: 500
            )
        }

        for (index, shape) in snapshot.unknownJSONShapes.enumerated() {
            AppLogger.audit(
                .runtimeStreamDebugSample,
                category: "Worker",
                taskID: task.id,
                fields: [
                    "runtime": runtime.rawValue,
                    "phase": phase,
                    "sample_kind": "unknown_json_shape",
                    "sample_index": String(index + 1),
                    "shape": shape
                ],
                level: .debug,
                fieldMaxLength: 500
            )
        }

        if let stderrTail = snapshot.stderrTail, !stderrTail.isEmpty {
            AppLogger.audit(
                .runtimeStreamDebugSample,
                category: "Worker",
                taskID: task.id,
                fields: [
                    "runtime": runtime.rawValue,
                    "phase": phase,
                    "sample_kind": "stderr_tail",
                    "tail": stderrTail
                ],
                level: .debug,
                fieldMaxLength: 500
            )
        }
    }

    static func unknownEventShapeFields(raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["raw_length": String(raw.count)]
        }

        var fields: [String: String] = [
            "raw_length": String(raw.count),
            "top_level_keys": object.keys.sorted().joined(separator: ",")
        ]
        if let dataObject = object["data"] as? [String: Any] {
            fields["data_keys"] = dataObject.keys.sorted().joined(separator: ",")
        }
        if let payloadObject = object["payload"] as? [String: Any] {
            fields["payload_keys"] = payloadObject.keys.sorted().joined(separator: ",")
        }
        if let type = object["type"] as? String {
            fields["type_field"] = type
        }
        return fields
    }
}
