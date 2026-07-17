import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

struct TaskExternalOperationSystemNotificationContent: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String

    static func make(_ notification: TaskExternalOperationNotification) -> Self {
        let state = TaskExternalOperationPresentation.executionLabel(notification.observation.executionState)
        let health = TaskExternalOperationPresentation.healthLabel(notification.observation.health)
        return Self(
            identifier: [
                "external-operation",
                notification.operationID.uuidString.lowercased(),
                notification.observation.executionState.rawValue,
                notification.observation.health.rawValue
            ].joined(separator: "."),
            title: "ASTRA external operation",
            body: "\(state) · \(health)"
        )
    }
}

protocol TaskExternalOperationSystemNotificationDelivering: Sendable {
    /// Best effort only. In-app task events remain the durable audit trail.
    func deliver(_ notification: TaskExternalOperationNotification) async
}

struct NoopTaskExternalOperationSystemNotificationDelivery:
    TaskExternalOperationSystemNotificationDelivering
{
    func deliver(_: TaskExternalOperationNotification) async {}
}

#if canImport(UserNotifications)
struct UserNotificationCenterExternalOperationDelivery:
    TaskExternalOperationSystemNotificationDelivering,
    @unchecked Sendable
{
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func deliver(_ notification: TaskExternalOperationNotification) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            // Monitoring must never trigger a permission prompt. Users opt in
            // through normal app notification settings.
            return
        }
        let rendered = TaskExternalOperationSystemNotificationContent.make(notification)
        let content = UNMutableNotificationContent()
        content.title = rendered.title
        content.body = rendered.body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(
                identifier: rendered.identifier,
                content: content,
                trigger: nil
            ))
        } catch {
            AppLogger.audit(.workerBlocked, category: "ExternalOperation", taskID: notification.taskID, fields: [
                "operation": "external_operation_system_notification",
                "result": "delivery_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
        }
    }
}
#endif
