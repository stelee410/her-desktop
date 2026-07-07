import SwiftUI

struct WorkspacePage<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(AppTheme.burgundy)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
                .padding(.top, 28)

                content
            }
            .padding(.horizontal, 38)
            .padding(.bottom, 34)
        }
    }
}

struct WorkspacePanel<Content: View>: View {
    var title: String
    var trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            content
        }
        .padding(14)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

struct WorkspaceMetric: View {
    var title: String
    var value: String
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WorkspaceActionButton: View {
    var title: String
    var icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct WorkspaceEventRow: View {
    var icon: String
    var title: String
    var detail: String
    var time: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.coral)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(time, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct EmptyWorkspaceLine: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.muted)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
