import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppViewModel
    private var memoryRows: [SidebarMemoryRowState] {
        SidebarStateBuilder().memoryRows(
            profile: model.agentProfile,
            signal: model.memorySignal,
            dreamContext: model.dreamContext,
            auditEvents: model.auditEvents
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Text("∞")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AppTheme.coral)
                Text("Her")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(AppTheme.coral)
            }
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(WorkspaceSection.allCases) { section in
                    NavItem(
                        icon: section.systemImage,
                        title: section.title,
                        selected: model.selectedSection == section
                    ) {
                        model.selectedSection = section
                    }
                }
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                Text("Our Connection")
                    .font(.caption)
                    .foregroundStyle(AppTheme.ink)
                HStack {
                    Image(systemName: "heart")
                        .foregroundStyle(AppTheme.coral)
                    Text(model.memorySignal.relationshipSummary)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.coral)
                }
                ProgressView(value: model.memorySignal.trust)
                    .tint(AppTheme.coral)
                Text("Mood: \(model.memorySignal.moodLabel)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Memory Signals")
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Image(systemName: model.agentProfile.known ? "checkmark.seal" : "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                ForEach(memoryRows) { row in
                    MemoryRow(row: row)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Circle()
                    .fill(AppTheme.coral.opacity(0.2))
                    .frame(width: 34, height: 34)
                    .overlay(Text(initials(model.agentProfile.displayName)).foregroundStyle(AppTheme.coral))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.agentProfile.displayName)
                        .font(.subheadline)
                    Text(model.connectionState.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(model.connectionState == .error ? .red : .green)
                }
                Spacer()
                Image(systemName: "gearshape")
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 18)
        .background(.ultraThinMaterial)
    }

    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "H" }
        return String(first).uppercased()
    }
}

private struct NavItem: View {
    var icon: String
    var title: String
    var selected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? AppTheme.coral : AppTheme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(selected ? AppTheme.rose.opacity(0.75) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MemoryRow: View {
    var row: SidebarMemoryRowState

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.rose.opacity(0.75))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: row.systemImage).font(.caption).foregroundStyle(AppTheme.coral))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }
        }
    }
}
