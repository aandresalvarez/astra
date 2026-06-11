import Foundation

/// Normalizes runtime text through advisory Astra protocol handling.
/// Runtime adapters should map assistant-visible CLI output into `.text(...)`
/// before this pipeline. Stderr, tool logs, and arbitrary process metadata should
/// not be scanned for protocol markers.
public struct AgentRuntimeEventPipeline: Sendable {
    private let supportsAstraRunProtocol: Bool
    private let stripsReasoningTags: Bool
    private var astraFilter = AstraRunProtocolTextFilter()
    private var reasoningFilter = LocalModelReasoningFilter()
    private var invalidAstraEventCount = 0
    private var emittedValidProtocolEvents: [AstraRunProtocolParsedEvent] = []

    public init(supportsAstraRunProtocol: Bool, stripsReasoningTags: Bool = false) {
        self.supportsAstraRunProtocol = supportsAstraRunProtocol
        self.stripsReasoningTags = stripsReasoningTags
    }

    public mutating func process(_ event: ParsedEvent) -> [ParsedEvent] {
        guard case .text(let text) = event else { return [event] }
        guard let visibleText = visibleText(from: text) else { return [] }
        guard supportsAstraRunProtocol else {
            return [.text(text: visibleText)]
        }
        return parsedEvents(from: astraFilter.process(text: visibleText).outputs)
    }

    public mutating func process(_ event: AgentEvent) -> [AgentEvent] {
        guard case .text(let text) = event else { return [event] }
        guard let visibleText = visibleText(from: text) else { return [] }
        guard supportsAstraRunProtocol else {
            return [.text(text: visibleText)]
        }
        return agentEvents(from: astraFilter.process(text: visibleText).outputs)
    }

    public mutating func flushParsedEvents() -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        if let visibleText = flushReasoningText() {
            if supportsAstraRunProtocol {
                events.append(contentsOf: parsedEvents(from: astraFilter.process(text: visibleText).outputs))
            } else {
                events.append(.text(text: visibleText))
            }
        }
        if supportsAstraRunProtocol {
            events.append(contentsOf: parsedEvents(from: astraFilter.flush().outputs))
        }
        return events
    }

    public mutating func flushAgentEvents() -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let visibleText = flushReasoningText() {
            if supportsAstraRunProtocol {
                events.append(contentsOf: agentEvents(from: astraFilter.process(text: visibleText).outputs))
            } else {
                events.append(.text(text: visibleText))
            }
        }
        if supportsAstraRunProtocol {
            events.append(contentsOf: agentEvents(from: astraFilter.flush().outputs))
        }
        return events
    }

    private mutating func visibleText(from text: String) -> String? {
        guard stripsReasoningTags else { return text }
        let visible = reasoningFilter.process(text: text)
        return visible.isEmpty ? nil : visible
    }

    private mutating func flushReasoningText() -> String? {
        guard stripsReasoningTags else { return nil }
        let visible = reasoningFilter.flush()
        return visible.isEmpty ? nil : visible
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
        guard case .invalid = event else {
            // Providers that stream partial messages deliver the same assistant
            // text twice (deltas, then the complete envelope), so the same
            // marker parses twice — and in multi-message turns the echo can
            // arrive after other markers. A marker identical to one already
            // emitted this run is a transport echo, not a new instruction
            // (every marker type is idempotent for identical payloads).
            if emittedValidProtocolEvents.contains(event) { return false }
            emittedValidProtocolEvents.append(event)
            return true
        }
        guard invalidAstraEventCount < AstraRunProtocolLimits.maxInvalidEventsPerRun else {
            return false
        }
        invalidAstraEventCount += 1
        return true
    }
}
