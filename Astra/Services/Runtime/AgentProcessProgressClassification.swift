import Foundation
import ASTRACore

extension AgentProcessMonitor {
    static func progressKind(for parsed: ParsedEvent) -> RuntimeProgressKind {
        switch parsed {
        case .control(let type):
            // Streaming a tool call's arguments, or a running tool's partial
            // stdout, is generation work rather than idle chatter: it can hold
            // the stream for minutes emitting nothing else, and treating it as
            // liveness gets the run killed mid-write by the semantic-progress
            // watchdog. Every runtime that streams work this way registers its
            // control type in `RuntimeProgressSignals`.
            return RuntimeProgressSignals.isProgressBearingControl(type)
                ? .actionableProgress
                : .providerLiveness
        case .systemInit: return .lifecycleMetadata
        case .unknown:
            return .diagnostic
        case .usage:
            return .accounting
        case .result:
            return .terminal
        case .astraProtocol:
            return .terminal
        case .text(let text):
            return nonEmpty(text) == nil ? .diagnostic : .visibleProgress
        case .thinking(let text):
            return nonEmpty(text) == nil ? .diagnostic : .providerLiveness
        case .toolResult(_, let content, _):
            return nonEmpty(content) == nil ? .diagnostic : .actionableProgress
        case .toolUse, .teammateStarted, .teammateCompleted, .teamCreated, .teamDeleted, .teamMessage, .permissionDenied:
            return .actionableProgress
        }
    }

    static func isSuccessfulTerminalProgress(_ parsed: ParsedEvent) -> Bool {
        switch parsed {
        case .astraProtocol(.valid(.complete)):
            return true
        case .result(_, _, _, _, _, _, let isError):
            return !isError
        default:
            return false
        }
    }

    static func repetitionSignature(_ parsed: ParsedEvent) -> String? {
        switch parsed {
        case .text(let text):
            return nonEmpty(text).map { textSignature(prefix: "text", text: $0) }
        case .thinking(let text):
            return nonEmpty(text).map { textSignature(prefix: "think", text: $0) }
        case .toolUse(let name, _, let input):
            return "tool:\(name):\(inputSignature(input))"
        case .toolResult(_, let content, _):
            return nonEmpty(content).map { textSignature(prefix: "tool.result", text: $0) }
        case .teammateStarted(_, let name, let prompt):
            return "teammate.start:\(name):\(textSignature(prefix: "prompt", text: prompt))"
        case .teammateCompleted(_, let name, let status):
            return "teammate.done:\(name):\(status.providerValue)"
        case .teamCreated(let name, let description):
            return "team.created:\(name):\(textSignature(prefix: "description", text: description))"
        case .teamDeleted(let name):
            return "team.deleted:\(name)"
        case .teamMessage(let from, let to, let content):
            return nonEmpty(content).map { textSignature(prefix: "team.msg:\(from)->\(to)", text: $0) }
        case .permissionDenied(let tool, let reason):
            return "perm.denied:\(tool):\(textSignature(prefix: "reason", text: reason))"
        case .control, .usage, .result, .systemInit, .astraProtocol, .unknown:
            return nil
        }
    }

    static func refreshesRuntimeActivity(_ parsed: ParsedEvent) -> Bool {
        refreshesRuntimeActivity(progressKind(for: parsed))
    }

    static func refreshesRuntimeActivity(_ progressKind: RuntimeProgressKind) -> Bool {
        switch progressKind {
        case .visibleProgress, .actionableProgress, .terminal:
            return true
        case .lifecycleMetadata, .providerLiveness, .accounting, .diagnostic:
            return false
        }
    }

    static func eventSignature(_ parsed: ParsedEvent) -> String {
        switch parsed {
        case .control(let type): return "control:\(type)"
        case .text(let t): return textSignature(prefix: "text", text: t)
        case .thinking(let t): return textSignature(prefix: "think", text: t)
        case .toolUse(let name, let id, let input):
            return "tool:\(name):\(id):\(inputSignature(input))"
        case .toolResult(let id, let content, let isError):
            return "\(textSignature(prefix: "tool.result:\(id):\(isError)", text: content))"
        case .usage(let input, let output): return "usage:\(input):\(output)"
        case .result(let t, _, _, _, _, _, _): return textSignature(prefix: "result", text: t ?? "")
        case .systemInit: return "init"
        case .teammateStarted(_, let name, _): return "teammate.start:\(name)"
        case .teammateCompleted(_, let name, let status): return "teammate.done:\(name):\(status.providerValue)"
        case .teamCreated(let name, _): return "team.created:\(name)"
        case .teamDeleted(let name): return "team.deleted:\(name)"
        case .teamMessage(let from, let to, let content): return textSignature(prefix: "team.msg:\(from)->\(to)", text: content)
        case .permissionDenied(let tool, _): return "perm.denied:\(tool)"
        case .astraProtocol: return "astra.protocol"
        case .unknown(let type): return "unknown:\(type)"
        }
    }

    private static func textSignature(prefix: String, text: String) -> String {
        "\(prefix):\(text.count):\(text.prefix(80))"
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func inputSignature(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        return valueSignature(input)
    }

    static func valueSignature(_ value: Any?) -> String {
        if let string = value as? String {
            return "s:\(string.count):\(string.prefix(80))"
        }
        if let dictionary = value as? [String: Any] {
            let joined = dictionary.keys.filter { $0 != ToolInputFingerprint.key }.sorted().map { key in
                "\(key)=\(valueSignature(dictionary[key]))"
            }.joined(separator: ";")
            return "d:\(joined.count):\(joined.prefix(120))"
        }
        if let array = value as? [Any] {
            let joined = array.map(valueSignature).joined(separator: ",")
            return "a:\(joined.count):\(joined.prefix(120))"
        }
        let description = String(describing: value ?? "")
        return "v:\(description.count):\(description.prefix(80))"
    }
}
