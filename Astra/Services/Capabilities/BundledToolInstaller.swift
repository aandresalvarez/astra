import Foundation

enum BundledToolInstaller {
    static func installBundledTools(bundle: Bundle = AstraResourceBundle.current) {
        guard let bundledTools = bundle.url(forResource: "Tools", withExtension: nil) else {
            return
        }

        let destination = URL(fileURLWithPath: RuntimePathResolver.astraToolsPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let tools = try FileManager.default.contentsOfDirectory(
                at: bundledTools,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for tool in tools {
                let target = destination.appendingPathComponent(tool.lastPathComponent)
                // Skip the delete+copy when the installed tool already matches
                // the bundled one (same size + mtime). Avoids ~MBs of clonefile
                // churn on every launch; fails safe to the copy path on any
                // resource-value read error.
                if FileManager.default.fileExists(atPath: target.path),
                   let sourceValues = try? tool.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   let targetValues = try? target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   sourceValues.fileSize == targetValues.fileSize,
                   sourceValues.contentModificationDate == targetValues.contentModificationDate {
                    continue
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: tool, to: target)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: target.path
                )
            }
        } catch {
            AppLogger.audit(.workerStarted, category: "Tools", fields: [
                "result": "bundled_tool_install_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
        }
    }
}
