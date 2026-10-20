import Foundation
import ASTRACore

enum CopilotStartupEvidence {
    static func directory(taskFolder: String, runID: UUID?) -> String? {
        guard !taskFolder.isEmpty, let runID else { return nil }
        return URL(fileURLWithPath: taskFolder).appendingPathComponent("diagnostics/copilot-\(runID.uuidString)").path
    }

    static func read(directory: String?, since startedAt: Date) -> String? {
        guard let directory else { return nil }
        let root = URL(fileURLWithPath: directory)
        let broker = HostFileAccessBroker()
        let files = ((try? broker.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            intent: .astraManagedStorage(root: root))) ?? []).filter {
                guard $0.pathExtension == "log", let values = try? $0.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate else { return false }
                return modified >= startedAt && modified <= Date().addingTimeInterval(1)
            }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(3)
        var errors: [String] = []
        for file in files {
            guard let data = try? broker.readData(at: file, maxBytes: 64 * 1_024,
                keeping: .suffix, intent: .astraManagedStorage(root: root)) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let lower = line.lowercased()
                guard lower.contains("[error]") || lower.hasPrefix("error:") || lower.contains("[fatal]") else { continue }
                errors.append(LogSanitizer.sanitize(String(line), maxLength: 400))
                if errors.count == 4 { return errors.joined(separator: "\n") }
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
