import Foundation

/// Normalizes runtime text through advisory Astra protocol handling.
/// Runtime adapters should map assistant-visible CLI output into `.text(...)`
/// before this pipeline. Stderr, tool logs, and arbitrary process metadata should
/// not be scanned for protocol markers.
public struct AgentRuntimeEventPipeline: Sendable {
    private let supportsAstraRunProtocol: Bool
    private var astraFilter = AstraRunProtocolTextFilter()
    private var invalidAstraEventCount = 0

    public init(supportsAstraRunProtocol: Bool) {
        self.supportsAstraRunProtocol = supportsAstraRunProtocol
    }

    public mutating func process(_ event: ParsedEvent) -> [ParsedEvent] {
        guard supportsAstraRunProtocol, case .text(let text) = event else {
            return [event]
        }
        return parsedEvents(from: astraFilter.process(text: text).outputs)
    }

    public mutating func process(_ event: AgentEvent) -> [AgentEvent] {
        guard supportsAstraRunProtocol, case .text(let text) = event else {
            return [event]
        }
        return agentEvents(from: astraFilter.process(text: text).outputs)
    }

    public mutating func flushParsedEvents() -> [ParsedEvent] {
        guard supportsAstraRunProtocol else { return [] }
        return parsedEvents(from: astraFilter.flush().outputs)
    }

    public mutating func flushAgentEvents() -> [AgentEvent] {
        guard supportsAstraRunProtocol else { return [] }
        return agentEvents(from: astraFilter.flush().outputs)
    }

    private mutating func parsedEvents(from outputs: [AstraRunProtocolTextFilterOutput]) -> [ParsedEvent] {
        outputs.compactMap { output in
            switch output {
            case .text(let text):
                return ParsedEvent.text(text: text)
            case .protocolEvent(let event):
                guard shouldEmit(protocolEvent: event) else { return nil }
                return .astraProtocol(event)
            }
        }
    }

    private mutating func agentEvents(from outputs: [AstraRunProtocolTextFilterOutput]) -> [AgentEvent] {
        outputs.compactMap { output in
            switch output {
            case .text(let text):
                return AgentEvent.text(text: text)
            case .protocolEvent(let event):
                guard shouldEmit(protocolEvent: event) else { return nil }
                return .astraProtocol(event)
            }
        }
    }

    private mutating func shouldEmit(protocolEvent event: AstraRunProtocolParsedEvent) -> Bool {
        guard case .invalid = event else { return true }
        guard invalidAstraEventCount < AstraRunProtocolLimits.maxInvalidEventsPerRun else {
            return false
        }
        invalidAstraEventCount += 1
        return true
    }
}
