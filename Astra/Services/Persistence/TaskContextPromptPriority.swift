import Foundation

/// Presentation policy only. The unabridged state and its source events remain
/// durable; optional history must not crowd out current instructions.
enum TaskContextPromptPriority {
    static func render(lines: [String], tail: String, limit: Int) -> String {
        let priorities = [
            "Thread Intent:", "- Current objective:", "- Approved goal:", "- Objective reconciliation:",
            "- Standing user instructions", "- Constraints:",
            "- Acceptance criteria:", "- Latest handoff:", "- Handoff unfinished work:", "- Verification:",
            "- Validation contract:", "- Blockers:", "- Next likely action:"
        ]
        struct Section {
            var lines: [String]
            let position: Int
            let priority: Int
        }
        var sections: [Section] = []
        for line in lines {
            let isHeader = (!line.hasPrefix(" ") && (!line.hasPrefix("- ") || line.hasSuffix(":")))
                || priorities.contains { line.hasPrefix($0) }
            if isHeader || sections.isEmpty {
                sections.append(Section(lines: [line], position: sections.count,
                    priority: priorities.firstIndex { line.hasPrefix($0) } ?? priorities.count))
            } else { sections[sections.count - 1].lines.append(line) }
        }
        // Keep the capsule introduction, then explicitly ranked working state.
        let introduction = sections.isEmpty ? "" : sections.removeFirst().lines.joined(separator: "\n")
        let ordered = sections.sorted {
            $0.priority == $1.priority ? $0.position < $1.position : $0.priority < $1.priority
        }
        let notice = "\n... (thread intent truncated) Retrieve canonical state for omitted detail."
        let budget = max(0, limit - tail.count - notice.count - 2)
        var body = String(introduction.prefix(budget))
        let texts = ordered.map { $0.lines.joined(separator: "\n") }
        var allocations = Array(repeating: 0, count: texts.count)
        var remaining = max(0, budget - body.count)
        let critical = ordered.indices.filter { ordered[$0].priority < priorities.count }
        // Reserve space for every current-state section before giving a long
        // instruction/constraint list the remaining budget.
        let floor = min(400, max(0, remaining / max(1, critical.count) - 1))
        for index in critical {
            allocations[index] = min(texts[index].count, floor)
            remaining -= allocations[index] + 1
        }
        for index in texts.indices {
            let separator = allocations[index] == 0 ? 1 : 0
            let addition = min(texts[index].count - allocations[index], max(0, remaining - separator))
            if addition > 0 { allocations[index] += addition; remaining -= addition + separator }
        }
        var omitted = introduction.count > budget
        for index in texts.indices {
            if allocations[index] > 0 { body += "\n" + String(texts[index].prefix(allocations[index])) }
            if allocations[index] < texts[index].count { omitted = true }
        }
        let result = body + (omitted ? notice : "") + "\n" + tail
        return String(result.prefix(max(0, limit)))
    }
}
