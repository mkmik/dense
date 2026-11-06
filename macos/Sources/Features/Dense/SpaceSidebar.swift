import SwiftUI

/// The sidebar on the left of the window: the Space tree from dennet. Clicking a Space
/// shows its tabs.
struct SpaceSidebar: View {
    @ObservedObject var store: SpaceStore = .shared
    @ObservedObject var tabs: SpaceTabs

    /// The fill of the selected row: the terminal's background, so it stands out from the
    /// tinted sidebar.
    let selection: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let problem = store.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Space.rows(Array(store.spaces.values))) { row in
                    SpaceRow(space: row.space)
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if row.id == tabs.selected {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selection)
                                    .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { tabs.select(row.space) }
                        .contextMenu {
                            Button("New Subspace…") { tabs.newSpace(parent: row.space) }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
        }
    }
}

/// One row: state dot, title, then an optional subtitle line and badge line.
private struct SpaceRow: View {
    let space: Space

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Self.color(space.spec.state))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name)
                    .lineLimit(1)
                if let subtitle = space.spec.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let badges = space.spec.badges, !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges.indices, id: \.self) { i in
                            let color = Self.color(badges[i].tone)
                            Text(badges[i].text)
                                .font(.caption2)
                                .foregroundStyle(color)
                                .padding(.horizontal, 4)
                                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
        }
    }

    /// Colors for both the state dot (idle, busy, waiting, error) and badge tones (info, muted, ...).
    private static func color(_ name: String?) -> Color {
        switch name {
        case "busy", "info": return .blue
        case "waiting", "warning": return .orange
        case "error": return .red
        case "success": return .green
        default: return .secondary
        }
    }
}
