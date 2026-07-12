import Foundation

public enum AstraRunProtocolEvent: Sendable, Equatable {
    public enum TodoStatus: String, Codable, Sendable, Equatable, Hashable {
        case pending
        case done
    }

    public struct TodoItem: Codable, Sendable, Equatable, Hashable {
        public let text: String
        public let status: TodoStatus

        public init(text: String, status: TodoStatus) {
            self.text = text
            self.status = status
        }
    }

    public enum PlanStepStatus: String, Codable, Sendable, Equatable, Hashable {
        case pending
        case running
        case blocked
        case done
        case skipped
    }

    public struct PlanStepProgress: Codable, Sendable, Equatable, Hashable {
        public let type: String
        public let planID: String?
        public let stepID: String
        public let status: PlanStepStatus
        public let title: String?
        public let detail: String?
        public let summary: String?
        public let reason: String?

        public init(
            type: String,
            planID: String?,
            stepID: String,
            status: PlanStepStatus,
            title: String? = nil,
            detail: String? = nil,
            summary: String? = nil,
            reason: String? = nil
        ) {
            self.type = type
            self.planID = planID
            self.stepID = stepID
            self.status = status
            self.title = title
            self.detail = detail
            self.summary = summary
            self.reason = reason
        }
    }

    case todoReplace(items: [TodoItem])
    case planStep(PlanStepProgress)
    case complete(summary: String, verifiedBy: String?)

    public var taskEventType: String {
        switch self {
        case .todoReplace:
            "astra.todo.replace"
        case .planStep(let progress):
            progress.type
        case .complete:
            "astra.complete"
        }
    }

    public var normalizedPayload: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data?
        switch self {
        case .todoReplace(let items):
            data = try? encoder.encode(NormalizedTodoReplace(items: items))
        case .planStep(let progress):
            data = try? encoder.encode(NormalizedPlanStep(progress: progress))
        case .complete(let summary, let verifiedBy):
            data = try? encoder.encode(NormalizedComplete(summary: summary, verifiedBy: verifiedBy))
        }

        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decodeNormalizedPayload(_ payload: String) -> AstraRunProtocolEvent? {
        guard let result = AstraRunProtocolParser.parseMarkerLine(AstraRunProtocolParser.markerPrefix + payload),
              case .valid(let event) = result else {
            return nil
        }
        return event
    }
}

public enum AstraRunProtocolLimits {
    public static let maxMarkerJSONBytes = 16 * 1024
    public static let maxTodoItems = 12
    public static let maxTodoItemTextCharacters = 180
    public static let maxCompletionSummaryCharacters = 1_200
    public static let maxVerifiedByCharacters = 240
    public static let maxPlanStepIDCharacters = 96
    public static let maxPlanStepTextCharacters = 500
    public static let maxInvalidEventsPerRun = 5
}

public enum AstraRunProtocolParsedEvent: Sendable, Equatable {
    case valid(AstraRunProtocolEvent)
    case invalid(reason: String)

    public var taskEventType: String {
        switch self {
        case .valid(let event):
            event.taskEventType
        case .invalid:
            "astra.protocol.invalid"
        }
    }

    public var normalizedPayload: String {
        switch self {
        case .valid(let event):
            return event.normalizedPayload
        case .invalid(let reason):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = NormalizedInvalid(reason: String(reason.prefix(160)))
            guard let data = try? encoder.encode(payload),
                  let string = String(data: data, encoding: .utf8) else {
                return #"{"reason":"invalid protocol marker","type":"protocol.invalid","v":1}"#
            }
            return string
        }
    }
}

public enum AstraRunProtocolTextFilterOutput: Sendable, Equatable {
    case text(String)
    case protocolEvent(AstraRunProtocolParsedEvent)
}

public struct AstraRunProtocolTextFilterResult: Sendable, Equatable {
    public let outputs: [AstraRunProtocolTextFilterOutput]

    public init(outputs: [AstraRunProtocolTextFilterOutput] = []) {
        self.outputs = outputs
    }
}

public struct AstraRunProtocolTextFilter: Sendable {
    private var bufferedLine = ""
    private var bufferedProtocolLine: String?

    public init() {}

    public mutating func process(text: String) -> AstraRunProtocolTextFilterResult {
        guard !text.isEmpty else { return AstraRunProtocolTextFilterResult() }

        var outputs: [AstraRunProtocolTextFilterOutput] = []
        var candidate = bufferedLine + text
        bufferedLine = ""

        while let newlineIndex = candidate.firstIndex(of: "\n") {
            let line = String(candidate[candidate.startIndex..<newlineIndex])
            appendCompleteLine(line, to: &outputs)
            candidate = String(candidate[candidate.index(after: newlineIndex)...])
        }

        guard !candidate.isEmpty else {
            return AstraRunProtocolTextFilterResult(outputs: outputs)
        }

        if bufferedProtocolLine != nil {
            if !appendProtocolContinuation(candidate, to: &outputs) {
                if shouldBuffer(candidate) {
                    bufferedLine = candidate
                } else {
                    outputs.append(.text(candidate))
                }
            }
        } else if shouldBuffer(candidate) {
            bufferedLine = candidate
        } else {
            outputs.append(.text(candidate))
        }

        return AstraRunProtocolTextFilterResult(outputs: outputs)
    }

    public mutating func flush() -> AstraRunProtocolTextFilterResult {
        var outputs: [AstraRunProtocolTextFilterOutput] = []
        if let bufferedProtocolLine {
            appendProtocolEvent(from: bufferedProtocolLine, to: &outputs)
            self.bufferedProtocolLine = nil
        }
        guard !bufferedLine.isEmpty else {
            return AstraRunProtocolTextFilterResult(outputs: outputs)
        }
        appendFinalLine(bufferedLine, to: &outputs)
        bufferedLine = ""
        return AstraRunProtocolTextFilterResult(outputs: outputs)
    }

    private mutating func appendCompleteLine(_ line: String, to outputs: inout [AstraRunProtocolTextFilterOutput]) {
        if bufferedProtocolLine != nil {
            if appendProtocolContinuation(line, to: &outputs) {
                return
            }
        }

        if let markerLine = markerLineCandidate(from: line) {
            appendProtocolMarkerOrBuffer(markerLine, to: &outputs)
            return
        }

        outputs.append(.text(line + "\n"))
    }

    private mutating func appendFinalLine(_ line: String, to outputs: inout [AstraRunProtocolTextFilterOutput]) {
        if bufferedProtocolLine != nil {
            if appendProtocolContinuation(line, to: &outputs) {
                return
            }
        }

        if let markerLine = markerLineCandidate(from: line) {
            appendProtocolMarkerOrBuffer(markerLine, to: &outputs, allowBuffer: false)
            return
        }

        outputs.append(.text(line))
    }

    @discardableResult
    private mutating func appendProtocolContinuation(
        _ line: String,
        to outputs: inout [AstraRunProtocolTextFilterOutput]
    ) -> Bool {
        guard var buffered = bufferedProtocolLine else { return false }
        guard looksLikeProtocolContinuation(line, after: buffered) else {
            appendProtocolEvent(from: buffered, to: &outputs)
            bufferedProtocolLine = nil
            return false
        }

        buffered += normalizedProtocolContinuation(line)
        if buffered.utf8.count > AstraRunProtocolLimits.maxMarkerJSONBytes {
            outputs.append(.protocolEvent(.invalid(reason: "marker JSON too large")))
            bufferedProtocolLine = nil
            return true
        }

        if let parsed = AstraRunProtocolParser.parseMarkerLine(buffered),
           !shouldBufferMalformedProtocol(parsed) {
            outputs.append(.protocolEvent(parsed))
            bufferedProtocolLine = nil
        } else {
            bufferedProtocolLine = buffered
        }
        return true
    }

    private mutating func appendProtocolMarkerOrBuffer(
        _ markerLine: String,
        to outputs: inout [AstraRunProtocolTextFilterOutput],
        allowBuffer: Bool = true
    ) {
        guard let parsed = AstraRunProtocolParser.parseMarkerLine(markerLine) else {
            return
        }

        if allowBuffer, shouldBufferMalformedProtocol(parsed) {
            bufferedProtocolLine = markerLine
            return
        }

        outputs.append(.protocolEvent(parsed))
    }

    private func appendProtocolEvent(from markerLine: String, to outputs: inout [AstraRunProtocolTextFilterOutput]) {
        if let parsed = AstraRunProtocolParser.parseMarkerLine(markerLine) {
            outputs.append(.protocolEvent(parsed))
        }
    }

    private func shouldBufferMalformedProtocol(_ parsed: AstraRunProtocolParsedEvent) -> Bool {
        guard case .invalid(let reason) = parsed else { return false }
        return reason == "malformed JSON" || reason == "missing JSON payload"
    }

    private func looksLikeProtocolContinuation(_ line: String, after buffered: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard markerLineCandidate(from: line) == nil else { return false }

        if isInsideJSONString(buffered) {
            return true
        }

        if trimmed.hasPrefix("\"") ||
            trimmed.hasPrefix("}") ||
            trimmed.hasPrefix("]") ||
            trimmed.hasPrefix(",") {
            return true
        }

        return trimmed.contains("\":") ||
            trimmed.contains("\",") ||
            trimmed.contains("\"}") ||
            trimmed.contains("\" ]") ||
            trimmed.contains("\" }")
    }

    private func normalizedProtocolContinuation(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isInsideJSONString(_ text: String) -> Bool {
        var quoteCount = 0
        var isEscaped = false
        for character in text {
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                quoteCount += 1
            }
        }
        return quoteCount % 2 == 1
    }

    private func shouldBuffer(_ candidate: String) -> Bool {
        guard let markerCandidate = markerPrefixCandidate(from: candidate) else { return false }
        return AstraRunProtocolParser.markerPrefix.hasPrefix(markerCandidate) ||
            markerCandidate.hasPrefix(AstraRunProtocolParser.markerPrefix)
    }

    private func markerLineCandidate(from line: String) -> String? {
        let candidate = markerPrefixCandidate(from: line)
        guard let candidate,
              candidate.hasPrefix(AstraRunProtocolParser.markerPrefix) else {
            return nil
        }
        return candidate
    }

    private func markerPrefixCandidate(from line: String) -> String? {
        var candidate = line.trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix(AstraRunProtocolParser.markerPrefix) ||
            AstraRunProtocolParser.markerPrefix.hasPrefix(candidate) {
            return candidate
        }

        for prefix in ["- ", "* ", "• ", "● ", "◦ ", "▪ ", "> "] {
            if candidate.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        if candidate.hasPrefix(AstraRunProtocolParser.markerPrefix) ||
            AstraRunProtocolParser.markerPrefix.hasPrefix(candidate) {
            return candidate
        }
        return nil
    }
}

public enum AstraRunProtocolDisplaySanitizer {
    public static func clean(_ text: String) -> String {
        guard text.mayContainRunProtocolLeak else { return text }

        var filter = AstraRunProtocolTextFilter()
        var visible = filter.process(text: text).outputs.visibleText
        visible += filter.flush().outputs.visibleText
        return removeOrphanProtocolFragments(from: visible)
    }

    private static func removeOrphanProtocolFragments(from text: String) -> String {
        guard text.mayContainRunProtocolLeak else { return text }

        let hadTrailingNewline = text.hasSuffix("\n")
        var kept: [String] = []
        var isDroppingContinuation = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.protocolDisplayCandidate

            if isDroppingContinuation {
                if trimmed.contains("}") {
                    isDroppingContinuation = false
                }
                continue
            }

            let dropReason = orphanProtocolDropReason(for: trimmed)
            guard dropReason.shouldDrop else {
                kept.append(line)
                continue
            }

            if !dropReason.isComplete {
                isDroppingContinuation = true
            }
        }

        var cleaned = kept.joined(separator: "\n")
        if hadTrailingNewline, !cleaned.hasSuffix("\n") {
            cleaned += "\n"
        }
        return cleaned
    }

    private static func orphanProtocolDropReason(for line: String) -> (shouldDrop: Bool, isComplete: Bool) {
        guard !line.isEmpty else { return (false, true) }

        if line.hasPrefix(AstraRunProtocolParser.markerPrefix) {
            return (true, line.contains("}"))
        }

        let protocolKeys = [
            "\"v\":",
            "\"type\":",
            "\"planID\":",
            "\"stepID\":",
            "\"status\":",
            "\"summary\":",
            "\"verifiedBy\":",
            "\"title\":",
            "\"detail\":",
            "\"reason\":"
        ]

        if line.hasPrefix(#"tepID":"#) ||
            line.hasPrefix("\"stepID\":") ||
            line.hasPrefix("\"planID\":") ||
            line.hasPrefix("\"status\":") ||
            line.hasPrefix("\"summary\":") ||
            line.hasPrefix("\"verifiedBy\":") ||
            line.hasPrefix("\"reason\":") ||
            line.hasPrefix("\"title\":") ||
            line.hasPrefix("\"detail\":") {
            return (true, line.contains("}"))
        }

        if line.contains("\"verifiedBy\":") {
            return (true, line.contains("}"))
        }

        if line.contains("\"planID\":"),
           protocolKeys.contains(where: { line.contains($0) }) {
            return (true, line.contains("}"))
        }

        return (false, true)
    }
}

public enum AstraRunProtocolParser {
    public static let markerPrefix = "ASTRA_EVENT "

    public static func parseMarkerLine(_ line: String) -> AstraRunProtocolParsedEvent? {
        guard line.hasPrefix(markerPrefix) else { return nil }

        let json = String(line.dropFirst(markerPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.utf8.count <= AstraRunProtocolLimits.maxMarkerJSONBytes else {
            return .invalid(reason: "marker JSON too large")
        }
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return .invalid(reason: "missing JSON payload")
        }

        let envelope: RawEnvelope
        do {
            envelope = try JSONDecoder().decode(RawEnvelope.self, from: data)
        } catch {
            return .invalid(reason: "malformed JSON")
        }

        guard let version = envelope.v else {
            return .invalid(reason: "missing version")
        }
        guard version == 1 else {
            return .invalid(reason: "unsupported version")
        }

        guard let type = envelope.type, !type.isEmpty else {
            return .invalid(reason: "missing type")
        }

        switch type {
        case "todo.replace":
            return parseTodoReplace(envelope)
        case "plan.step.started", "plan.step.completed", "plan.step.blocked", "plan.step.skipped":
            return parsePlanStep(envelope, type: type)
        case "complete":
            return parseComplete(envelope)
        default:
            return .invalid(reason: "unsupported type")
        }
    }

    private static func parseTodoReplace(_ envelope: RawEnvelope) -> AstraRunProtocolParsedEvent {
        guard let rawItems = envelope.items, !rawItems.isEmpty else {
            return .invalid(reason: "missing todo items")
        }
        guard rawItems.count <= AstraRunProtocolLimits.maxTodoItems else {
            return .invalid(reason: "too many todo items")
        }

        var items: [AstraRunProtocolEvent.TodoItem] = []
        items.reserveCapacity(rawItems.count)

        for rawItem in rawItems {
            guard let text = rawItem.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .invalid(reason: "invalid todo item")
            }
            guard text.count <= AstraRunProtocolLimits.maxTodoItemTextCharacters else {
                return .invalid(reason: "todo item too long")
            }
            guard let statusValue = rawItem.status,
                  let status = AstraRunProtocolEvent.TodoStatus(rawValue: statusValue) else {
                return .invalid(reason: "invalid todo status")
            }
            items.append(AstraRunProtocolEvent.TodoItem(text: text, status: status))
        }

        return .valid(.todoReplace(items: items))
    }

    private static func parsePlanStep(_ envelope: RawEnvelope, type: String) -> AstraRunProtocolParsedEvent {
        guard let stepID = envelope.stepID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stepID.isEmpty else {
            return .invalid(reason: "missing stepID")
        }
        guard stepID.count <= AstraRunProtocolLimits.maxPlanStepIDCharacters else {
            return .invalid(reason: "stepID too long")
        }

        let status: AstraRunProtocolEvent.PlanStepStatus
        if let rawStatus = envelope.status,
           let decoded = AstraRunProtocolEvent.PlanStepStatus(rawValue: rawStatus) {
            status = decoded
        } else {
            switch type {
            case "plan.step.started": status = .running
            case "plan.step.completed": status = .done
            case "plan.step.blocked": status = .blocked
            case "plan.step.skipped": status = .skipped
            default: return .invalid(reason: "unsupported plan step type")
            }
        }

        let progress = AstraRunProtocolEvent.PlanStepProgress(
            type: type,
            planID: envelope.planID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            stepID: stepID,
            status: status,
            title: envelope.title?.boundedPlanText,
            detail: envelope.detail?.boundedPlanText,
            summary: envelope.summary?.boundedPlanText,
            reason: envelope.reason?.boundedPlanText
        )
        return .valid(.planStep(progress))
    }

    private static func parseComplete(_ envelope: RawEnvelope) -> AstraRunProtocolParsedEvent {
        guard let summary = envelope.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return .invalid(reason: "missing completion summary")
        }
        guard summary.count <= AstraRunProtocolLimits.maxCompletionSummaryCharacters else {
            return .invalid(reason: "completion summary too long")
        }

        let verifiedBy = envelope.verifiedBy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if let verifiedBy, verifiedBy.count > AstraRunProtocolLimits.maxVerifiedByCharacters {
            return .invalid(reason: "verification summary too long")
        }

        return .valid(.complete(summary: summary, verifiedBy: verifiedBy))
    }
}

private struct RawEnvelope: Decodable {
    public let v: Int?
    public let type: String?
    public let items: [RawTodoItem]?
    public let summary: String?
    public let verifiedBy: String?
    public let planID: String?
    public let stepID: String?
    public let status: String?
    public let title: String?
    public let detail: String?
    public let reason: String?
}

private struct RawTodoItem: Decodable {
    public let text: String?
    public let status: String?
}

private struct NormalizedTodoReplace: Encodable {
    public let v = 1
    public let type = "todo.replace"
    public let items: [AstraRunProtocolEvent.TodoItem]
}

private struct NormalizedPlanStep: Encodable {
    public let v = 1
    public let type: String
    public let planID: String?
    public let stepID: String
    public let status: AstraRunProtocolEvent.PlanStepStatus
    public let title: String?
    public let detail: String?
    public let summary: String?
    public let reason: String?

    public init(progress: AstraRunProtocolEvent.PlanStepProgress) {
        type = progress.type
        planID = progress.planID
        stepID = progress.stepID
        status = progress.status
        title = progress.title
        detail = progress.detail
        summary = progress.summary
        reason = progress.reason
    }
}

private struct NormalizedComplete: Encodable {
    public let v = 1
    public let type = "complete"
    public let summary: String
    public let verifiedBy: String?
}

private struct NormalizedInvalid: Encodable {
    public let v = 1
    public let type = "protocol.invalid"
    public let reason: String
}

private extension [AstraRunProtocolTextFilterOutput] {
    var visibleText: String {
        compactMap { output -> String? in
            guard case .text(let text) = output else { return nil }
            return text
        }.joined()
    }
}

private extension String {
    var mayContainRunProtocolLeak: Bool {
        contains("ASTRA_EVENT") ||
            contains(#"tepID":"#) ||
            contains("\"stepID\":") ||
            contains("\"planID\":") ||
            contains("\"verifiedBy\":")
    }

    var protocolDisplayCandidate: String {
        var candidate = trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* ", "• ", "● ", "◦ ", "▪ ", "> "] {
            if candidate.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return candidate
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var boundedPlanText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(AstraRunProtocolLimits.maxPlanStepTextCharacters))
    }
}
