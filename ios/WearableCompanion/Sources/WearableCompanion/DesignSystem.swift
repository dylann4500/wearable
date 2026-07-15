import SwiftUI

struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusBadge: View {
    var status: RecordingStatus

    var body: some View {
        Label(status.displayName, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .uploaded: .blue
        case .processing: .orange
        case .complete: .green
        case .failed: .red
        }
    }

    private var systemImage: String {
        switch status {
        case .uploaded: "tray.and.arrow.up"
        case .processing: "hourglass"
        case .complete: "checkmark.circle"
        case .failed: "xmark.octagon"
        }
    }
}

extension Double {
    var shortMetric: String {
        if rounded() == self {
            return String(Int(self))
        }
        return String(format: "%.1f", self)
    }
}

extension Date {
    var relativeLabel: String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: .now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
