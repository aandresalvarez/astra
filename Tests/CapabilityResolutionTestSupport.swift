import Foundation
import Testing
import ASTRACore
@testable import ASTRA

enum CapabilityResolutionTestSupport {
    /// Override only default readers. Explicit private libraries still read
    /// their own installed definitions, including version and digest changes.
    static func inputs(packages: [PluginPackage]) -> CapabilityResolutionInputs {
        let packs = AstraPackCatalog()
        return CapabilityResolutionInputs(
            libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: packages,
            approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [],
            packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL,
            packCatalog: .init(entries: [], diagnostics: []))
    }
}

/// Migration fixtures accept bundled definitions. Keep each test's default
/// resolver on those same definitions, independent of the user's library.
struct BuiltInCapabilityFixture: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let inputs = CapabilityResolutionTestSupport.inputs(packages: PluginCatalog.builtInPackages)
        try await CapabilityResolutionInputs.$pinned.withValue(inputs) {
            try await function()
        }
    }
}
