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
    @State private var showInfoPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                Label {
                    Text("Transform rules apply after transcription. Use for punctuation cleanup, deletions, or regex patterns.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Button(action: { showInfoPopover.toggle() }) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showInfoPopover) {
                        TextRulesInfoPopover()
                    }
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

struct TextRulesInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pattern Examples")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                patternExample(
                    mode: "Literal",
                    pattern: "...",
                    replacement: "",
                    description: "Delete ellipsis (works for any punctuation)"
                )

                patternExample(
                    mode: "Literal",
                    pattern: " ,",
                    replacement: ",",
                    description: "Fix space before comma"
                )

                Divider()

                patternExample(
                    mode: "Whole Word",
                    pattern: "um",
                    replacement: "",
                    description: "Delete filler word (won't match \"umbrella\")"
                )

                patternExample(
                    mode: "Whole Word",
                    pattern: "dont",
                    replacement: "don't",
                    description: "Fix missing apostrophe"
                )

                Divider()

                patternExample(
                    mode: "Regex",
                    pattern: "\\s{2,}",
                    replacement: " ",
                    description: "Collapse multiple spaces"
                )

                patternExample(
                    mode: "Regex",
                    pattern: "^\\s+|\\s+$",
                    replacement: "",
                    description: "Trim leading/trailing whitespace"
                )
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func patternExample(mode: String, pattern: String, replacement: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(mode)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(4)

                Text(pattern)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(replacement.isEmpty ? "(delete)" : replacement)
                    .font(.system(size: 12, design: replacement.isEmpty ? .default : .monospaced))
                    .italic(replacement.isEmpty)
                    .foregroundColor(replacement.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
