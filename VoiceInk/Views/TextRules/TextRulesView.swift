import SwiftUI
import SwiftData

struct TextRulesView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CompactHeroSection(
                    icon: "doc.text.magnifyingglass",
                    title: "Text Transform",
                    description: "Apply text transformations after transcription for cleanup and formatting",
                    maxDescriptionWidth: 500
                )

                TextRulesContentView()
                    .padding(.horizontal, 32)
                    .padding(.vertical, 40)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct TextRulesContentView: View {
    @Query(sort: \TextRule.priority) private var rules: [TextRule]
    @Environment(\.modelContext) private var modelContext
    @State private var editingRule: TextRule?
    @State private var showAddSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                Label {
                    Text("Transform rules apply after transcription. Use for punctuation cleanup, deletions, or regex patterns.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                }
            }

            HStack {
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            }

            if !rules.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Pattern")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Mode")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 80)

                        Text("Replacement")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rules) { rule in
                                RuleRow(
                                    rule: rule,
                                    onEdit: { editingRule = rule },
                                    onDelete: { deleteRule(rule) },
                                    onToggle: { toggleRule(rule) }
                                )

                                if rule.id != rules.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                .background(CardBackground(isSelected: false))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No transform rules yet")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(CardBackground(isSelected: false))
            }
        }
        .sheet(isPresented: $showAddSheet) {
            RuleEditorSheet(modelContext: modelContext)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(rule: rule, modelContext: modelContext)
        }
        .alert("Text Transform", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func deleteRule(_ rule: TextRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }

    private func toggleRule(_ rule: TextRule) {
        rule.isEnabled.toggle()
        try? modelContext.save()
    }
}
