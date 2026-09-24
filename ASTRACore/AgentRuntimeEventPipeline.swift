import Foundation

/// Normalizes runtime text through advisory Astra protocol handling.
/// Runtime adapters should map assistant-visible CLI output into `.text(...)`
/// or `.assistantMessage(...)` before this pipeline. Stderr, tool logs, and
/// arbitrary process metadata should not be scanned for protocol markers.
///
/// Keyed assistant text is resolved to its message key here, and each key gets
/// its own marker filter, so line buffering never splices two messages
/// together. A message's final copy is filtered whole and leaves as one final
/// fragment: split into lines, an echo of it could not be told from new text.
public struct AgentRuntimeEventPipeline: Sendable {
    private let supportsAstraRunProtocol: Bool
    private var astraFilter = AstraRunProtocolTextFilter()
    private var invalidAstraEventCount = 0
    private var emittedValidProtocolEvents: [AstraRunProtocolParsedEvent] = []
    private var messageIdentity = AssistantMessageIdentityResolver()
    private var messageFilters: [String: AstraRunProtocolTextFilter] = [:]
    /// Keys with an open delta filter, in first-seen order for `flush`.
    private var openMessageKeys: [String] = []
    private var subagentMessageKeys: Set<String> = []
    private var finalizedMessageKeys: Set<String> = []

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
        if case .assistantMessage(let message) = event {
            return process(message)
        }
        guard supportsAstraRunProtocol, case .text(let text) = event else {
            return [event]
        }
        return agentEvents(from: astraFilter.process(text: text).outputs)
    }

    private mutating func process(_ message: AssistantMessageEvent) -> [AgentEvent] {
        switch messageIdentity.resolve(message) {
        case .consumed:
            return []
        case .unkeyed(let text):
            return process(AgentEvent.text(text: text))
        case .fragment(let fragment):
            // A delta that arrives after its message's final copy is stale.
            if fragment.kind == .delta, finalizedMessageKeys.contains(fragment.key) {
                return []
            }
            guard supportsAstraRunProtocol else {
                if fragment.kind == .final { finalizedMessageKeys.insert(fragment.key) }
                return [.assistantMessage(.fragment(fragment))]
            }
            switch fragment.kind {
            case .delta:
                var filter = messageFilters[fragment.key] ?? AstraRunProtocolTextFilter()
                if messageFilters[fragment.key] == nil {
                    openMessageKeys.append(fragment.key)
                    if fragment.isSubagent { subagentMessageKeys.insert(fragment.key) }
                }
                let outputs = filter.process(text: fragment.text).outputs
                messageFilters[fragment.key] = filter
                return keyedEvents(from: outputs, like: fragment)
            case .final:
                messageFilters[fragment.key] = nil
                openMessageKeys.removeAll { $0 == fragment.key }
                finalizedMessageKeys.insert(fragment.key)
                var filter = AstraRunProtocolTextFilter()
                var visibleText = ""
                var protocolEvents: [AgentEvent] = []
                for output in filter.process(text: fragment.text).outputs + filter.flush().outputs {
                    switch output {
                    case .text(let text):
                        visibleText += text
                    case .protocolEvent(let event):
                        if shouldEmit(protocolEvent: event) {
                            protocolEvents.append(.astraProtocol(event))
                        }
                    }
                }
                return protocolEvents + [.assistantMessage(.fragment(AssistantMessageFragment(
                    key: fragment.key,
                    kind: .final,
                    text: visibleText,
                    isSubagent: fragment.isSubagent
                )))]
            }
        }
    }

    private mutating func keyedEvents(
        from outputs: [AstraRunProtocolTextFilterOutput],
        like fragment: AssistantMessageFragment
    ) -> [AgentEvent] {
        outputs.compactMap { output in
            switch output {
            case .text(let text):
                return .assistantMessage(.fragment(AssistantMessageFragment(
                    key: fragment.key,
                    kind: .delta,
                    text: text,
                    isSubagent: fragment.isSubagent
                )))
            case .protocolEvent(let event):
                guard shouldEmit(protocolEvent: event) else { return nil }
                return .astraProtocol(event)
            }
        }
    }

    public mutating func flushParsedEvents() -> [ParsedEvent] {
        guard supportsAstraRunProtocol else { return [] }
        return parsedEvents(from: astraFilter.flush().outputs)
    }

    public mutating func flushAgentEvents() -> [AgentEvent] {
        guard supportsAstraRunProtocol else { return [] }
        var events = agentEvents(from: astraFilter.flush().outputs)
        for key in openMessageKeys {
            guard var filter = messageFilters[key] else { continue }
            events += keyedEvents(
                from: filter.flush().outputs,
                like: AssistantMessageFragment(
                    key: key,
                    kind: .delta,
                    text: "",
                    isSubagent: subagentMessageKeys.contains(key)
                )
            )
            messageFilters[key] = filter
        }
        openMessageKeys.removeAll()
        return events
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
