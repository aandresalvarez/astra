import Foundation
import ASTRACore
import ASTRAModels

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
        guard let data = raw.data(using: .utf8) else {
            return [
                "raw_length": String(raw.count),
                "decode_error": "utf8_encoding_failed"
            ]
        }

        let shape: UnknownStreamEventShape
        do {
            shape = try JSONDecoder().decode(UnknownStreamEventShape.self, from: data)
        } catch {
            return [
                "raw_length": String(raw.count),
                "decode_error": decodeErrorSummary(error)
            ]
        }

        var fields: [String: String] = [
            "raw_length": String(raw.count),
            "top_level_keys": shape.topLevelKeys.joined(separator: ",")
        ]
        if !shape.dataKeys.isEmpty {
            fields["data_keys"] = shape.dataKeys.joined(separator: ",")
        }
        if !shape.payloadKeys.isEmpty {
            fields["payload_keys"] = shape.payloadKeys.joined(separator: ",")
        }
        if let type = shape.type {
            fields["type_field"] = type
        }
        return fields
    }

    private struct UnknownStreamEventShape: Decodable {
        let topLevelKeys: [String]
        let dataKeys: [String]
        let payloadKeys: [String]
        let type: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            topLevelKeys = container.allKeys.map(\.stringValue).sorted()
            dataKeys = Self.nestedKeys(named: "data", in: container)
            payloadKeys = Self.nestedKeys(named: "payload", in: container)
            type = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("type"))
        }

        private static func nestedKeys(
            named name: String,
            in container: KeyedDecodingContainer<DynamicCodingKey>
        ) -> [String] {
            let key = DynamicCodingKey(name)
            guard let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key) else {
                return []
            }
            return nested.allKeys.map(\.stringValue).sorted()
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private static func decodeErrorSummary(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted:
            "data_corrupted"
        case DecodingError.typeMismatch:
            "type_mismatch"
        case DecodingError.valueNotFound:
            "value_not_found"
        case DecodingError.keyNotFound:
            "key_not_found"
        default:
            "decode_failed"
        }
    }
}
