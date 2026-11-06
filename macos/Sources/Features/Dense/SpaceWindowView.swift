import SwiftUI

/// A dense window's content, laid out like Rex: the content runs under a transparent
/// titlebar. On the left, the Space sidebar on a tinted background goes up to the top of
/// the window, below the window buttons. On the right, the selected Space's tabs sit in
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
            SpaceSidebar(tabs: tabs, selection: ghostty.config.backgroundColor)
                .padding(.top, Self.titlebarHeight + 6)
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
                // A grey wash over the terminal background, so the tint follows the theme.
                .background(Color(white: 0.5).opacity(0.15))
            VStack(spacing: 0) {
                SurfaceTabBar(tabs: tabs, surfaces: tabs.selected.flatMap { store.spaces[$0] }?
                    .terminals(Array(store.surfaces.values)))
                    .frame(height: Self.titlebarHeight)
                if tabs.selected != nil && tabs.active == nil {
                    Text(store.loaded ? "No tabs in this Space" : "")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    terminal.padding(.leading, 8)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The Space's tabs, left-aligned in the titlebar row: a terminal icon and title each,
/// the one in front on a light pill, then a button that makes a new tab. Without a
/// selected Space the row is empty.
private struct SurfaceTabBar: View {
    @ObservedObject var tabs: SpaceTabs
    let surfaces: [Surface]?

    var body: some View {
        HStack(spacing: 2) {
            if let surfaces {
                ForEach(surfaces, id: \.id) { surface in
                    let front = surface.id == tabs.active
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
                }
                Button { tabs.newTab(nil) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Tab")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
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

private struct TerminalTitle: View {
    @ObservedObject var view: Ghostty.SurfaceView
    let fallback: String

    var body: some View {
        // Ghostty shows 👻 while a terminal has not set a title.
        Text(view.title.isEmpty || view.title == "👻" ? fallback : view.title)
    }
}
