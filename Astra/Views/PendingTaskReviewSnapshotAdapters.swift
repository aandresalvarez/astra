import Foundation

extension PendingTaskReviewRunSnapshot {
    init(_ snapshot: TaskRunSnapshot) {
        self.init(
            id: snapshot.id,
            status: snapshot.status,
            startedAt: snapshot.startedAt,
            completedAt: snapshot.completedAt,
            stopReason: snapshot.stopReason
        )
    }
}

extension PendingTaskReviewEventSnapshot {
    init(_ snapshot: TaskEventSnapshot) {
        self.init(runID: snapshot.runID, type: snapshot.type, timestamp: snapshot.timestamp)
    }
}
