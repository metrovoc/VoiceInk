import SwiftUI

struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                AppIconView()

                VStack(spacing: 10) {
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        Text("VoiceInk CE")
                            .font(.system(size: 34, weight: .bold))

                        Text("v\(appVersion)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }

                    Text("Speech-to-text for macOS")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Label("A personal fork of VoiceInk", systemImage: "person.crop.circle")
                        .font(.headline)

                    Text("Maintained for local workflow needs, with focused reliability work and small experiments.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .background(CardBackground(isSelected: false))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    resourceButton("Source", systemImage: "chevron.left.forwardslash.chevron.right", url: AppLinks.repository)
                    resourceButton("Changelog", systemImage: "list.bullet.clipboard.fill", url: AppLinks.releases)
                    resourceButton("Feedback", systemImage: "exclamationmark.bubble.fill", url: AppLinks.newIssue)
                    resourceButton("Docs", systemImage: "book.fill", url: AppLinks.documentation)
                }
                .frame(maxWidth: 640)

            }
            .padding(.vertical, 48)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func resourceButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
