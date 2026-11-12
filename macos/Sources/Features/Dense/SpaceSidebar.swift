import SwiftUI

/// The sidebar on the left of the window: the Space tree from dennet, in one section per
/// machine. This machine's Spaces come first, then each Host's, each under the machine's
/// name and a line. Clicking a Space shows its tabs. A Space can be dragged up or down
/// among its siblings, taking its subspaces along; a drag never changes its parent.
///
/// It is set in the terminals' font, one text line per row as in a terminal. View > Show
/// Tree Lines draws lines from each Space to its subspaces.
struct SpaceSidebar: View {
    @ObservedObject var store: SpaceStore = .shared
    @ObservedObject var tabs: SpaceTabs

    /// The fill of the selected row: the terminal's background, so it stands out from the
    /// tinted sidebar.
    let selection: Color

    /// How the terminals draw text, which the Space titles copy.
    let look: TerminalLook
    private var font: NSFont { look.font }

    @AppStorage(SidebarMenu.treeLinesKey) private var treeLines = false

    /// The Space being dragged, and how far it has moved.
    @State private var drag: (id: String, dy: CGFloat)?
    /// The middle of each row, to work out where a dragged Space lands.
    @State private var middles: [String: CGFloat] = [:]
    /// Whether the filter field is open, and the text in it.
    @State private var filtering = false
    @State private var filter = ""
    @State private var filterHover = false
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            spaces
            filterBar
        }
        .font(Font(font))
    }

    private var cell: CGSize { look.cell }

    /// The bottom of the sidebar, laid out like Rex's: a filter icon that never moves. On
    /// hover a light pill shows behind it with the word "Filter"; a click turns the word
    /// into a field that filters the Spaces by title, or by tag with "#tag", on a darker pill while it has the
    /// focus. Esc, or leaving the field empty, closes it.
    private var filterBar: some View {
        HStack(spacing: 7) {
            Image(systemName: filter.isEmpty
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(filterFocused ? .primary : .secondary)
            if filtering {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onExitCommand { closeFilter() }
                if !filter.isEmpty {
                    Button(action: closeFilter) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            } else if filterHover {
                Text("Filter").foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 7.5)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .background(Capsule().fill(Color.primary.opacity(filterFocused ? 0.075 : filterHover || filtering ? 0.037 : 0)))
        .contentShape(Capsule())
        .onHover { filterHover = $0 }
        .onTapGesture {
            filtering = true
            // Once the field is there.
            DispatchQueue.main.async { filterFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: SpaceTabs.focusFilter)) { note in
            guard note.object as AnyObject? === tabs else { return }
            filtering = true
            // After the command palette has given the focus back to the terminal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { filterFocused = true }
        }
        .onChange(of: filterFocused) { focused in
            if !focused && filter.isEmpty { closeFilter() }
        }
        .padding(.horizontal, 7)
        .padding(.top, 4)
        .padding(.bottom, 6.5)
    }

    private func closeFilter() {
        filter = ""
        filtering = false
        filterFocused = false
    }

    /// The rows of one machine's Spaces, through the filter.
    private func rows(on host: String?) -> [Space.Row] {
        Space.filter(Space.rows(store.spaces(on: host)), filter)
    }

    private var spaces: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let problem = store.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                // nil is this machine.
                ForEach([nil] + store.hostNames.map(Optional.some), id: \.self) { host in
                    let rows = self.rows(on: host)
                    // While filtering, a machine with no match is left out.
                    if filter.isEmpty || !rows.isEmpty {
                        HostHeader(name: host ?? "localhost", look: look)
                        if let host, let problem = store.hostProblems[host] {
                            Text(problem).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        }
                        let guides = treeLines ? Space.guides(rows) : [:]
                        ForEach(rows) { row in
                            self.row(row, among: rows, guide: guides[row.id])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .coordinateSpace(name: "spaces")
            .onPreferenceChange(RowMiddles.self) { middles = $0 }
            .background(NoBounce())
        }
    }

    /// One Space's row. `rows` are the rows of its section; `guide` is set when tree
    /// lines are shown.
    private func row(_ row: Space.Row, among rows: [Space.Row], guide: Space.Guide?) -> some View {
        let dy = drag.flatMap { Self.subtree($0.id, rows).contains(row.id) ? $0.dy : nil }
        let cell = self.cell
        // With tree lines, a subspace's dot sits 5 columns right of its parent's, after
        // "├─ " under the parent's title; without, 2 columns.
        return SpaceRow(space: row.space, look: look, cell: cell)
            .padding(.leading, CGFloat(row.depth * (guide == nil ? 2 : 5)) * cell.width)
            .background(alignment: .leading) {
                if let guide, row.depth > 0 { TreeLines(guide: guide, cell: cell) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if row.id == tabs.selected {
                    RoundedRectangle(cornerRadius: 4)
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
            // No reordering while filtering: hidden siblings would lose their place.
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("spaces"))
                .onChanged { drag = (row.id, $0.translation.height) }
                .onEnded { value in
                    // The Space goes after its siblings whose middle is above the mouse.
                    let siblings = rows.filter { $0.parent == row.parent }
                    tabs.moveSpace(row.id, among: siblings.map(\.space), to: siblings.filter {
                        $0.id != row.id && middles[$0.id, default: 0] < value.location.y
                    }.count)
                    drag = nil
                }, including: filter.isEmpty ? .all : .subviews)
            .contextMenu {
                Button("New Subspace…") { tabs.newSpace(parent: row.space) }
                Button("Rename…") { tabs.renameSpace(row.space) }
                Button("Edit Tags…") { tabs.editTags(row.space) }
                Divider()
                Button("Archive Space…") { tabs.archiveSpace(row.space) }
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
    let look: TerminalLook

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TerminalText(text: name, look: look, opacity: 0.55)
            Rectangle().frame(height: 1).opacity(0.4)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// The lines from a Space up to its parent, as a terminal tree draws them with box
/// characters: a line down through each level whose Space has siblings still to come,
/// then "├─" (or "└─" for the last child) into this row's dot. In columns of the font, a
/// row at depth d has its dot at column 5d, and the line into it starts at 5d - 3.
private struct TreeLines: View {
    let guide: Space.Guide
    let cell: CGSize

    var body: some View {
        GeometryReader { g in
            Path { path in
                let mid = cell.height / 2
                for (level, through) in guide.through.enumerated() where through {
                    let x = x(level)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: g.size.height))
                }
                let depth = guide.through.count
                let x = x(depth)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: guide.last ? mid : g.size.height))
                path.move(to: CGPoint(x: x, y: mid))
                path.addLine(to: CGPoint(x: CGFloat(5 * depth - 1) * cell.width, y: mid))
            }
            .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
        }
    }

    /// The middle of the column the line down for `level` (1 ...) runs in.
    private func x(_ level: Int) -> CGFloat {
        (CGFloat(5 * level - 3) + 0.5) * cell.width
    }
}

/// Stops the scroll view it sits in from scrolling past its top or bottom edge (the
/// rubber-band bounce), for this scroll view only. Turning the scroll view's elasticity
/// off is not enough: SwiftUI's scroll view still overshoots with a real trackpad. So
/// each time the scroll position changes, this moves it back inside the content.
private struct NoBounce: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clamp), name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func clamp(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            // The furthest the clip view may scroll, without the overshoot.
            let origin = clip.constrainBoundsRect(clip.bounds).origin
            if origin != clip.bounds.origin { clip.setBoundsOrigin(origin) }
        }
    }
}

private struct RowMiddles: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One row: state dot in one column, a space, then the title; then an optional subtitle
/// line under the title, and badges on the title's line. Open Space (⌘K) shows them too.
struct SpaceRow: View {
    let space: Space
    let look: TerminalLook
    let cell: CGSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Idle (or unset) is a hollow ring; every other state is a filled dot.
            Group {
                if space.spec.state == nil || space.spec.state == "idle" {
                    Circle().strokeBorder(Self.color(space.spec.state), lineWidth: 1)
                } else {
                    Circle().fill(Self.color(space.spec.state))
                }
            }
                .frame(width: 7, height: 7)
                .frame(width: cell.width, height: cell.height)
            VStack(alignment: .leading, spacing: 0) {
                // The title on the left, the badges in a line on the right, truncating the title first.
                HStack(spacing: 4) {
                    TerminalText(text: space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name, look: look)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let badges = space.spec.badges, !badges.isEmpty {
                        ForEach(badges.indices, id: \.self) { i in
                            let color = Self.color(badges[i].tone)
                            Text(badges[i].text)
                                .foregroundStyle(color)
                                .fixedSize()
                        }
                    }
                }
                .frame(height: cell.height)
                if let subtitle = space.spec.subtitle, !subtitle.isEmpty {
                    TerminalText(text: subtitle, look: look, opacity: 0.55)
                        .frame(height: cell.height)
                }
            }
            .padding(.leading, cell.width)
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
