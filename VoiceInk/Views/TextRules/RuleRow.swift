import SwiftUI

struct RuleRow: View {
    let rule: TextRule
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    @State private var isEditHovered = false
    @State private var isDeleteHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(rule.pattern)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(rule.isEnabled ? .primary : .secondary)

            Text(rule.matchMode.rawValue)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
                .frame(width: 80)

            Text(rule.replacement.isEmpty ? "(delete)" : rule.replacement)
                .font(.system(size: 13, design: rule.replacement.isEmpty ? .default : .monospaced))
                .italic(rule.replacement.isEmpty)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(rule.isEnabled ? (rule.replacement.isEmpty ? .secondary : .primary) : .secondary)

            HStack(spacing: 6) {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(isEditHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Edit rule")
                .onHover { isEditHovered = $0 }

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isDeleteHovered ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete rule")
                .onHover { isDeleteHovered = $0 }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .opacity(rule.isEnabled ? 1 : 0.6)
    }
}
