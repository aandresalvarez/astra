import Foundation

enum AppUpdateSafety {
    static func isInstallBlocked(
        queueIsProcessing: Bool,
        activeWorkerCount: Int,
        activeTaskCount: Int,
        runningTaskCount: Int
    ) -> Bool {
        queueIsProcessing
            || activeWorkerCount > 0
            || activeTaskCount > 0
            || runningTaskCount > 0
    }
}
