import SwiftUI

/// The sidebar on the left of the window: the Space tree from dennet, in one section per
/// machine. This machine's Spaces come first, then each Host's, each under the machine's
/// name and a line. Clicking a Space shows its tabs. A Space can be dragged up or down
/// among its siblings, taking its subspaces along; a drag never changes its parent.
struct SpaceSidebar: View {
    @ObservedObject var store: SpaceStore = .shared
    @ObservedObject var tabs: SpaceTabs

    /// The fill of the selected row: the terminal's background, so it stands out from the
    /// tinted sidebar.
    let selection: Color

    /// The Space being dragged, and how far it has moved.
    @State private var drag: (id: String, dy: CGFloat)?
    /// The middle of each row, to work out where a dragged Space lands.
    @State private var middles: [String: CGFloat] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let problem = store.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                // nil is this machine.
                ForEach([nil] + store.hostNames.map(Optional.some), id: \.self) { host in
                    let rows = Space.rows(store.spaces(on: host))
                    HostHeader(name: host ?? "localhost")
                    if let host, let problem = store.hostProblems[host] {
                        Text(problem).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    ForEach(rows) { row in
                        self.row(row, among: rows)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .coordinateSpace(name: "spaces")
            .onPreferenceChange(RowMiddles.self) { middles = $0 }
        }
    }

    /// One Space's row. `rows` are the rows of its section.
    private func row(_ row: Space.Row, among rows: [Space.Row]) -> some View {
        let dy = drag.flatMap { Self.subtree($0.id, rows).contains(row.id) ? $0.dy : nil }
        return SpaceRow(space: row.space)
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
            .background(GeometryReader { g in
                Color.clear.preference(key: RowMiddles.self, value: [row.id: g.frame(in: .named("spaces")).midY])
            })
            .offset(y: dy ?? 0)
            .zIndex(dy == nil ? 0 : 1)
            .onTapGesture { tabs.select(row.space) }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("spaces"))
                .onChanged { drag = (row.id, $0.translation.height) }
                .onEnded { value in
                    // The Space goes after its siblings whose middle is above the mouse.
                    let siblings = rows.filter { $0.parent == row.parent }
                    tabs.moveSpace(row.id, among: siblings.map(\.space), to: siblings.filter {
                        $0.id != row.id && middles[$0.id, default: 0] < value.location.y
                    }.count)
                    drag = nil
                })
            .contextMenu {
                Button("New Subspace…") { tabs.newSpace(parent: row.space) }
                Divider()
                Button("Delete Space…", role: .destructive) { tabs.deleteSpace(row.space) }
            }
    }

    /// The ids of a row and the rows under it, which follow it until one is no deeper.
    private static func subtree(_ id: String, _ rows: [Space.Row]) -> Set<String> {
        guard let start = rows.firstIndex(where: { $0.id == id }) else { return [] }
        let depth = rows[start].depth
        let end = rows[(start + 1)...].firstIndex { $0.depth <= depth } ?? rows.endIndex
        return Set(rows[start..<end].map(\.id))
    }
}

/// A machine's name and a line, above its Spaces: smaller than a Space's title, in grey.
private struct HostHeader: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.subheadline).lineLimit(1)
            Rectangle().frame(height: 1).opacity(0.4)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct RowMiddles: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
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
