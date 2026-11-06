import SwiftUI

/// A dense window's content: the Space sidebar on the left; on the right, the selected
/// Space's tab bar above the terminal.
struct SpaceWindowView<Terminal: View>: View {
    @ObservedObject var tabs: SpaceTabs
    @ObservedObject var store: SpaceStore = .shared
    let terminal: Terminal

    init(tabs: SpaceTabs, @ViewBuilder terminal: () -> Terminal) {
        self.tabs = tabs
        self.terminal = terminal()
    }

    var body: some View {
        HStack(spacing: 0) {
            SpaceSidebar(tabs: tabs)
            Divider()
            VStack(spacing: 0) {
                if let space = tabs.selected.flatMap({ store.spaces[$0] }) {
                    SurfaceTabBar(tabs: tabs, surfaces: space.terminals(Array(store.surfaces.values)))
                }
                if tabs.selected != nil && tabs.active == nil {
                    Text(store.loaded ? "No tabs in this Space" : "")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    terminal
                }
            }
        }
    }
}

/// A row of equal-width tabs, one per Surface, in the style of the macOS tab bar, and a
/// button that makes a new tab.
private struct SurfaceTabBar: View {
    @ObservedObject var tabs: SpaceTabs
    let surfaces: [Surface]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(surfaces, id: \.id) { surface in
                    title(surface)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(surface.id == tabs.active ? Color.clear : Color.primary.opacity(0.07))
                        .contentShape(Rectangle())
                        .onTapGesture { tabs.show(surface) }
                    Divider()
                }
                Button { tabs.newTab(nil) } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New Tab")
            }
            .frame(height: 28)
            Divider()
        }
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
