import Foundation

struct WorkspaceAppDueAutomation: Sendable, Equatable {
    var automationID: String
    var actionID: String
    var scheduledAt: Date
}

struct WorkspaceAppAutomationScheduler {
    func dueAutomations(
        manifest: WorkspaceAppManifest,
        states: [WorkspaceAppAutomationState],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WorkspaceAppDueAutomation] {
        let specsByID = Dictionary(uniqueKeysWithValues: manifest.automations.map { ($0.id, $0) })
        return states.compactMap { state in
            guard state.isEnabled,
                  state.status == .enabled,
                  let spec = specsByID[state.automationID],
                  let actionID = state.actionID ?? spec.action,
                  !actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let scheduledAt = state.nextRunAt ?? nextRunDate(for: spec, after: state.updatedAt, calendar: calendar)
            guard let scheduledAt, scheduledAt <= now else {
                return nil
            }
            return WorkspaceAppDueAutomation(
                automationID: state.automationID,
                actionID: actionID,
                scheduledAt: scheduledAt
            )
        }
        .sorted {
            if $0.scheduledAt != $1.scheduledAt {
                return $0.scheduledAt < $1.scheduledAt
            }
            return $0.automationID < $1.automationID
        }
    }

    func nextRunDate(
        for automation: WorkspaceAppAutomationSpec,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard automation.type == "schedule" || automation.type == "monitor" else { return nil }
        switch automation.scheduleType {
        case "interval":
            guard let seconds = automation.intervalSeconds, seconds > 0 else { return nil }
            return date.addingTimeInterval(TimeInterval(seconds))
        case "daily":
            guard let hour = automation.dailyHour,
                  let minute = automation.dailyMinute,
                  (0...23).contains(hour),
                  (0...59).contains(minute) else {
                return nil
            }
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime
            )
        case "weekly":
            guard let hour = automation.dailyHour,
                  let minute = automation.dailyMinute,
                  let weekday = automation.weeklyDayOfWeek,
                  (0...23).contains(hour),
                  (0...59).contains(minute),
                  (1...7).contains(weekday) else {
                return nil
            }
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                matchingPolicy: .nextTime
            )
        default:
            return nil
        }
    }

    func markRunCompleted(
        automation: WorkspaceAppAutomationState,
        spec: WorkspaceAppAutomationSpec,
        completedAt: Date = Date(),
        calendar: Calendar = .current
    ) {
        automation.lastRunAt = completedAt
        automation.nextRunAt = nextRunDate(for: spec, after: completedAt, calendar: calendar)
        automation.status = automation.isEnabled ? .enabled : .disabled
        automation.updatedAt = completedAt
    }
}
