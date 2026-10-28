enum ControlledBrowserRunState: String, CaseIterable {
    case idle
    case launching
    case running
    case attached
    case stopped
    case waitingForProfile
    case failed

    var label: String {
        switch self {
        case .idle: "Not launched"
        case .launching: "Opening"
        case .running: "Connected"
        case .attached: "Connected"
        case .stopped: "Control disconnected"
        case .waitingForProfile: "Waiting for profile"
        case .failed: "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .launching: "arrow.triangle.2.circlepath"
        case .running: "checkmark.circle.fill"
        case .attached: "link.circle.fill"
        case .stopped: "stop.circle"
        case .waitingForProfile: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
