import Foundation
import ASTRAModels

/// Scope denials override ambient writable support roots (for example /tmp),
/// while preserving explicitly owned descendants such as this task's ledger.
struct ExecutionResourceScopeSandbox: Equatable, Sendable {
    let profile: String
    let arguments: [String]
    let deniedRoots: [String]
    private let writableRoots: [String]

    init(scope: TaskExecutionResourceScope?) {
        guard let scope else {
            profile = ""
            arguments = []
            deniedRoots = []
            writableRoots = []
            return
        }
        let roots = Array(Set(scope.readOnlyRoots.compactMap(ExecutionSandbox.canonicalize))).sorted()
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
        writableRoots = writers
    }

    func deniesWrite(to path: String) -> Bool {
        guard let path = ExecutionSandbox.canonicalize(path) else { return false }
        return deniedRoots.contains { root in
            TaskExecutionResourceScope.contains(root, path) && !writableRoots.contains { writer in
                writer != root && TaskExecutionResourceScope.contains(root, writer)
                    && TaskExecutionResourceScope.contains(writer, path)
            }
        }
    }
}
