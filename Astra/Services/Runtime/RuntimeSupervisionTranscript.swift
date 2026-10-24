import Foundation
import ASTRACore

final class RuntimeSupervisionTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var errors = 0
    var text: String { lock.lock(); defer { lock.unlock() }; return tail }
    var stderrBytes: Int { lock.lock(); defer { lock.unlock() }; return errors }
    func append(_ text: String, stderr: Bool, taskID: UUID) {
        lock.lock(); defer { lock.unlock() }
        if stderr { errors += text.utf8.count }
        tail = String((tail + text).suffix(1_200))
        tail = RunSecretRedactionScope.redact(tail, taskID: taskID)
    }
}
