import Foundation

/// Slice 5b: the renderable form a "form" view presents — its visible fields evaluated against the
/// current draft record. `visibleWhen` is honored with the SAME Slice 5a branching analyzer that
/// validated it, so what the form shows matches what REDCap's branching means (for the safe subset).
/// Pure + non-`@MainActor`; the SwiftUI form control surface consumes these presentations.
struct WorkspaceAppFormFieldPresentation: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var label: String
    var fieldType: String
    var required: Bool
    var readOnly: Bool
    var readOnlyReason: String?
    var choices: [WorkspaceAppFormChoice]
    var value: WorkspaceAppStorageValue?
}

enum WorkspaceAppFormPresentationBuilder {
    /// The fields to render for `view`, in declaration order, with branch-hidden fields dropped.
    static func presentation(
        view: WorkspaceAppViewSpec,
        draft: [String: WorkspaceAppStorageValue] = [:]
    ) -> [WorkspaceAppFormFieldPresentation] {
        view.formFields.compactMap { field in
            guard isVisible(field, draft: draft) else { return nil }
            return WorkspaceAppFormFieldPresentation(
                name: field.name,
                label: field.label,
                fieldType: field.fieldType,
                required: field.required,
                readOnly: field.readOnly,
                readOnlyReason: field.readOnlyReason,
                choices: field.choices ?? [],
                value: draft[field.name]
            )
        }
    }

    static func isVisible(_ field: WorkspaceAppFormFieldSpec, draft: [String: WorkspaceAppStorageValue]) -> Bool {
        guard let logic = field.visibleWhen, !logic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        // The validator guarantees only safe logic is persisted; if anything else slips through,
        // fail OPEN (show the field) rather than silently hiding required inputs.
        guard case .safe(let condition) = WorkspaceAppREDCapBranchingAnalyzer.classify(logic) else { return true }
        return evaluate(condition, against: draft)
    }

    static func evaluate(
        _ condition: WorkspaceAppREDCapBranchingCondition,
        against draft: [String: WorkspaceAppStorageValue]
    ) -> Bool {
        guard !condition.clauses.isEmpty else { return true }
        let results = condition.clauses.map { evaluate(clause: $0, draft: draft) }
        return condition.combinator == .or ? results.contains(true) : results.allSatisfy { $0 }
    }

    private static func evaluate(
        clause: WorkspaceAppREDCapBranchingCondition.Clause,
        draft: [String: WorkspaceAppStorageValue]
    ) -> Bool {
        let actual = stringValue(draft[clause.field])
        switch clause.comparison {
        case .equals:
            return actual == clause.value
        case .notEquals:
            return actual != clause.value
        case .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual:
            if let a = Double(actual), let b = Double(clause.value) {
                return compare(a, b, clause.comparison)
            }
            return compareLexical(actual, clause.value, clause.comparison)
        }
    }

    private static func compare(_ a: Double, _ b: Double, _ op: WorkspaceAppREDCapBranchingCondition.Comparison) -> Bool {
        switch op {
        case .greaterThan: return a > b
        case .lessThan: return a < b
        case .greaterOrEqual: return a >= b
        case .lessOrEqual: return a <= b
        default: return false
        }
    }

    private static func compareLexical(_ a: String, _ b: String, _ op: WorkspaceAppREDCapBranchingCondition.Comparison) -> Bool {
        switch op {
        case .greaterThan: return a > b
        case .lessThan: return a < b
        case .greaterOrEqual: return a >= b
        case .lessOrEqual: return a <= b
        default: return false
        }
    }

    /// Normalize a stored value to the string form REDCap branching compares against. A yesno/bool
    /// field stores 1/0, matching clauses like `[consent] = '1'`.
    private static func stringValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .text(let text): return text
        case .integer(let int): return String(int)
        case .real(let real): return String(real)
        case .bool(let bool): return bool ? "1" : "0"
        case .null, .none: return ""
        }
    }
}
