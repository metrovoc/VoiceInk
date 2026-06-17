import AppKit

struct IssueReporter {
    static func openFeedbackPage() {
        NSWorkspace.shared.open(AppLinks.newIssue)
    }
}
