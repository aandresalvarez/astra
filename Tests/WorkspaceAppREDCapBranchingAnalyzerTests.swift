import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App REDCap Branching Analyzer (Slice 5)")
struct WorkspaceAppREDCapBranchingAnalyzerTests {
    private typealias Condition = WorkspaceAppREDCapBranchingCondition

    private func safeCondition(_ logic: String) -> Condition? {
        if case let .safe(condition) = WorkspaceAppREDCapBranchingAnalyzer.classify(logic) { return condition }
        return nil
    }

    private func isUnsupported(_ logic: String) -> Bool {
        if case .unsupported = WorkspaceAppREDCapBranchingAnalyzer.classify(logic) { return true }
        return false
    }

    // MARK: - Safe subset

    @Test("empty branching logic means always visible")
    func emptyIsAlwaysVisible() {
        let condition = safeCondition("   ")
        #expect(condition?.isAlwaysVisible == true)
    }

    @Test("a single comparison parses into a normalized clause")
    func singleComparison() throws {
        let condition = try #require(safeCondition("[age] >= '18'"))
        #expect(condition.clauses.count == 1)
        #expect(condition.clauses[0].field == "age")
        #expect(condition.clauses[0].comparison == .greaterOrEqual)
        #expect(condition.clauses[0].value == "18")  // quotes stripped
    }

    @Test("equality, inequality, and bare numbers are all safe")
    func variousOperators() throws {
        #expect(safeCondition("[status] = 'active'")?.clauses.first?.comparison == .equals)
        #expect(safeCondition("[score] <> '0'")?.clauses.first?.comparison == .notEquals)
        #expect(safeCondition("[score] != '0'")?.clauses.first?.comparison == .notEquals)
        #expect(safeCondition("[count] > 5")?.clauses.first?.value == "5")
    }

    @Test("a homogeneous AND chain is safe")
    func andChain() throws {
        let condition = try #require(safeCondition("[a] = '1' and [b] = '2'"))
        #expect(condition.combinator == .and)
        #expect(condition.clauses.map(\.field) == ["a", "b"])
    }

    @Test("a homogeneous OR chain is safe and case-insensitive")
    func orChain() throws {
        let condition = try #require(safeCondition("[a] = '1' OR [b] = '2'"))
        #expect(condition.combinator == .or)
        #expect(condition.clauses.count == 2)
    }

    @Test("field names that merely contain 'and'/'or' are not split")
    func fieldNamesContainingKeywords() throws {
        // 'brand' contains 'and'; 'score' contains 'or' — neither is whitespace-delimited.
        #expect(safeCondition("[brand] = 'acme'")?.clauses.count == 1)
        #expect(safeCondition("[score] = '1'")?.clauses.count == 1)
    }

    // MARK: - Unsupported (must block / route to review)

    @Test("function calls are unsupported")
    func functionsUnsupported() {
        #expect(isUnsupported("datediff([dob], 'today', 'y') > 18"))
        #expect(isUnsupported("if([a] = '1', 1, 0)"))
    }

    @Test("mixed and/or without grouping is unsupported")
    func mixedCombinatorsUnsupported() {
        #expect(isUnsupported("[a] = '1' and [b] = '2' or [c] = '3'"))
    }

    @Test("grouping parentheses are unsupported")
    func parenthesesUnsupported() {
        #expect(isUnsupported("([a] = '1')"))
    }

    @Test("arithmetic is unsupported")
    func arithmeticUnsupported() {
        #expect(isUnsupported("[a] + [b] = '2'"))
    }

    @Test("smart variables / event or checkbox codes are unsupported")
    func smartVariablesUnsupported() {
        #expect(isUnsupported("[visit_1][weight] > '0'"))
        #expect(isUnsupported("[race___1] = '1' and [event][field] = '2'"))
    }

    @Test("malformed or partial conditions are unsupported (conservative default)")
    func malformedUnsupported() {
        #expect(isUnsupported("[a]"))                 // no operator
        #expect(isUnsupported("[a] = '1' and "))      // trailing empty clause
        #expect(isUnsupported("a = 1"))               // missing brackets
        #expect(isUnsupported("not([a] = '1')"))      // negation (function + parens)
    }
}
