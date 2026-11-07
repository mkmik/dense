import SwiftUI

/// A dense window's content, laid out like Rex: the content runs under a transparent
/// titlebar. On the left, the Space sidebar on a tinted background goes up to the top of
/// the window, below the window buttons, with a button that makes a new Space at the right
/// of the titlebar row. On the right, the selected Space's tabs sit in
/// the titlebar row, above the terminal.
struct SpaceWindowView<Terminal: View>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var tabs: SpaceTabs
    @ObservedObject var store: SpaceStore = .shared
    let terminal: Terminal

    /// The height of the titlebar row the window buttons sit in.
    static var titlebarHeight: CGFloat { 28 }

    init(ghostty: Ghostty.App, tabs: SpaceTabs, @ViewBuilder terminal: () -> Terminal) {
        self.ghostty = ghostty
        self.tabs = tabs
        self.terminal = terminal()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                // The titlebar row, right of the window buttons.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NotWindowDraggable(content: Button { tabs.newSpace(parent: nil) } label: {
                        Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New Space"))
                }
                .padding(.horizontal, 8)
                .frame(height: Self.titlebarHeight)
                SpaceSidebar(tabs: tabs, selection: ghostty.config.backgroundColor)
            }
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            // A grey wash over the terminal background, so the tint follows the theme.
            .background(Color(white: 0.5).opacity(0.15))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // In the titlebar row a drag moves the window, unless the view under
                    // the mouse says no. The tabs say no, so they can be dragged instead.
                    NotWindowDraggable(content: SurfaceTabBar(
                        tabs: tabs,
                        surfaces: tabs.selected.flatMap { store.spaces[$0] }?.terminals(Array(store.surfaces.values))))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: Self.titlebarHeight)
                if tabs.selected != nil && (tabs.active == nil || tabs.waiting) {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    terminal.padding(.leading, 8)
                }
            }
        }
        // The theme's background under everything, the same color the selected row
        // uses. The window's own background follows the focused terminal, and with no
        // terminal it can stay white.
        // ponytail: with background-opacity below 1 the terminal area gets the
        // opacity twice; draw this only outside the terminal if that bothers anyone.
        .background(ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity))
        .ignoresSafeArea(.container, edges: .top)
    }

    /// What a Space shows when it has no terminal to show.
    private var placeholder: String {
        // Blank while the Space is not there, as when its Host has not answered yet.
        guard store.loaded, tabs.selected.flatMap({ store.spaces[$0] }) != nil else { return "" }
        guard let active = tabs.active else { return "No tabs in this Space" }
        switch store.surfaces[active].flatMap(store.den(of:))?.status?.phase {
        case nil, "Pending", "Running": return "This den is not running yet"
        case let phase?: return "This den is not running (\(phase))"
        }
    }
}

/// Shows its content in its own hosting view, which does not let a drag on it move the window.
private struct NotWindowDraggable<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NonDraggableHostingView<Content> {
        let view = NonDraggableHostingView(rootView: content)
        // It sits under the titlebar, which would push its content down out of view.
        if #available(macOS 13.3, *) { view.safeAreaRegions = [] }
        return view
    }
    func updateNSView(_ view: NonDraggableHostingView<Content>, context: Context) { view.rootView = content }

    /// Only as wide as the content, so the rest of the row still moves the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NonDraggableHostingView<Content>, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// The Space's tabs, left-aligned in the titlebar row: a terminal icon and title each,
/// the one in front on a light pill, then a button that makes a new tab. Without a
/// selected Space the row is empty. A tab can be dragged to another place in the row.
private struct SurfaceTabBar: View {
    @ObservedObject var tabs: SpaceTabs
    let surfaces: [Surface]?
    /// The tab being dragged, and how far it has moved.
    @State private var drag: (id: String, dx: CGFloat)?
    /// The middle of each tab, to work out where a dragged tab lands.
    @State private var middles: [String: CGFloat] = [:]

    var body: some View {
        HStack(spacing: 2) {
            if let surfaces {
                ForEach(surfaces, id: \.id) { surface in
                    let front = surface.id == tabs.active
                    let dx = drag?.id == surface.id ? drag?.dx : nil
                    Button { tabs.show(surface) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal").imageScale(.small)
                            title(surface).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(front ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(front ? .primary : .secondary)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TabMiddles.self, value: [surface.id: g.frame(in: .named("tabs")).midX])
                    })
                    .offset(x: dx ?? 0)
                    .zIndex(dx == nil ? 0 : 1)
                    .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("tabs"))
                        .onChanged { drag = (surface.id, $0.translation.width) }
                        .onEnded { value in
                            // The tab goes after the other tabs whose middle is left of the mouse.
                            tabs.move(surface.id, to: surfaces.filter {
                                $0.id != surface.id && middles[$0.id, default: 0] < value.location.x
                            }.count)
                            drag = nil
                        })
                }
                Button { tabs.newTab(nil) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Tab")
            }
        }
        .coordinateSpace(name: "tabs")
        .onPreferenceChange(TabMiddles.self) { middles = $0 }
    }

    /// The Surface's title if it has one, else the terminal's own title.
    @ViewBuilder
    private func title(_ surface: Surface) -> some View {
        if let title = surface.spec.title, !title.isEmpty {
            Text(title)
        } else if let view = tabs.terminal(for: surface) {
            TerminalTitle(view: view, fallback: surface.metadata.name)
        } else {
            Text(surface.metadata.name)
        }
    }
}

private struct TabMiddles: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TerminalTitle: View {
    @ObservedObject var view: Ghostty.SurfaceView
    let fallback: String

    var body: some View {
        // Ghostty shows 👻 while a terminal has not set a title.
        Text(view.title.isEmpty || view.title == "👻" ? fallback : view.title)
    }
}
