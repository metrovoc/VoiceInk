import SwiftUI

struct HelpAndResourcesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Help & Resources")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 10) {
                resourceLink(
                    icon: "book.fill",
                    title: "Documentation",
                    color: AppTheme.Sidebar.models,
                    url: AppLinks.documentation
                )

                resourceLink(
                    icon: "list.bullet.clipboard.fill",
                    title: "Changelog",
                    color: AppTheme.Sidebar.dashboard,
                    url: AppLinks.releases
                )

                resourceLink(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Source Code",
                    color: AppTheme.Sidebar.dictionary,
                    url: AppLinks.repository
                )
                
                resourceLink(
                    icon: "exclamationmark.bubble.fill",
                    title: "Feedback or Issues?",
                    color: AppTheme.Sidebar.audio,
                    action: {
                        IssueReporter.openFeedbackPage()
                    }
                )
            }
        }
        .padding(18)
        .background(AppCardBackground(cornerRadius: 28))
    }
    
    private func resourceLink(icon: String, title: LocalizedStringKey, color: Color, url: URL? = nil, action: (() -> Void)? = nil) -> some View {
        Button(action: {
            if let action = action {
                action()
            } else if let url {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 10) {
                DashboardIconGlyph(systemName: icon, color: color, size: 15, frameSize: 20)
                
                Text(title)
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(AppTheme.Surface.subtle)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        }
        .buttonStyle(.plain)
    }
}
