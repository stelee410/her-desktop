import SwiftUI

struct Panel<Content: View>: View {
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
        .padding(12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

struct PlanLine: View {
    var done: Bool
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : AppTheme.muted)
            Text(title)
                .font(.caption)
            Spacer()
        }
    }
}

struct WorkPlanStepLine: View {
    var step: WorkPlan.Step

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption)
                    .lineLimit(2)
                if let detail = step.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(step.status.displayName)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var icon: String {
        switch step.status {
        case .pending: return "circle"
        case .inProgress: return "clock"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch step.status {
        case .pending: return AppTheme.muted
        case .inProgress: return AppTheme.coral
        case .done: return .green
        case .blocked: return .orange
        }
    }
}

struct MetricBox: View {
    var title: String
    var value: Double
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Gauge(value: value) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(AppTheme.coral)
            Text("\(Int(value * 100))%")
                .font(.caption.weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(Color.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WaveLineTiny: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for x in stride(from: rect.minX, through: rect.maxX, by: 5) {
            let p = (x - rect.minX) / max(rect.width, 1)
            path.addLine(to: CGPoint(x: x, y: rect.midY + sin(p * .pi * 4) * 4))
        }
        return path
    }
}
