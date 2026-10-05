import Foundation
import ASTRAModels

/// Scope denials override ambient writable support roots (for example /tmp),
/// while preserving explicitly owned descendants such as this task's ledger.
struct ExecutionResourceScopeSandbox {
    let profile: String
    let arguments: [String]
    let deniedRoots: [String]

    init(scope: TaskExecutionResourceScope?) {
        guard let scope else {
            profile = ""
            arguments = []
            deniedRoots = []
            return
        }
        let readers = scope.resources.filter {
            $0.access == .shared && ($0.role == .execution || $0.role == .additionalFolder)
        }.compactMap { ExecutionSandbox.canonicalize($0.path) }
        let roots = Array(Set(readers + scope.replacedCheckoutPaths.compactMap(ExecutionSandbox.canonicalize))).sorted()
        let writers = scope.resources.filter { $0.access == .exclusive }.compactMap { ExecutionSandbox.canonicalize($0.path) }
        var rules: [String] = []
        var parameters: [String] = []
        for (index, root) in roots.enumerated() {
            let parameter = "ASTRA_SCOPE_READ_\(index)"
            parameters += ["-D", "\(parameter)=\(root)"]
            var filters = ["(require-any (literal (param \"\(parameter)\")) (subpath (param \"\(parameter)\")))"]
            let descendants = Array(Set(writers.filter {
                $0 != root && TaskExecutionResourceScope.contains(root, $0)
            })).sorted()
            for (childIndex, child) in descendants.enumerated() {
                let exception = "ASTRA_SCOPE_WRITE_\(index)_\(childIndex)"
                parameters += ["-D", "\(exception)=\(child)"]
                filters.append("(require-not (require-any (literal (param \"\(exception)\")) (subpath (param \"\(exception)\"))))")
            }
            rules.append("(deny file-write* (require-all \(filters.joined(separator: " "))))")
        }
        profile = "\n" + rules.joined(separator: "\n")
        arguments = parameters
        deniedRoots = roots
    }
}
