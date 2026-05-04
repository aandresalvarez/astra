import AppKit
import Foundation

enum AstraAboutInfo {
    static let fullName = "Agent Scheduler for Tasks, Runs, and Automation"
    static let tagline = "A macOS command center for supervising delegated AI work."
    static let repositoryURLString = "https://github.com/susom/astra"

    static let summary = "ASTRA helps you create durable workspaces, assign AI-powered tasks, review what changed, and decide when an agent should keep going, pause, or ask for help."

    static let supervisionPrinciple = "Supervise meaningful work, not raw transcripts."

    static let highlights = [
        "Create durable workspaces for projects and recurring workflows.",
        "Queue, run, resume, and review delegated AI tasks.",
        "Connect skills, tools, local CLIs, and plugin capabilities.",
        "Track runs, artifacts, schedules, logs, and task history.",
        "Keep supervision calm, readable, and grounded in trust signals."
    ]

    static var creditsPlainText: String {
        """
        \(fullName)

        \(tagline)

        \(summary)

        \(highlights.map { "• \($0)" }.joined(separator: "\n"))

        \(repositoryURLString)
        """
    }

    @MainActor
    static func creditsAttributedString() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 7

        return NSAttributedString(
            string: creditsPlainText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}
