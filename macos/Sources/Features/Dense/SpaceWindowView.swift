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
                    Text("No tabs in this Space")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    terminal
                }
            }
        }
    }
}

/// A row of equal-width tabs, one per Surface, in the style of the macOS tab bar.
private struct SurfaceTabBar: View {
    @ObservedObject var tabs: SpaceTabs
    let surfaces: [Surface]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(surfaces, id: \.id) { surface in
                    Text(surface.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? surface.metadata.name)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(surface.id == tabs.active ? Color.clear : Color.primary.opacity(0.07))
                        .contentShape(Rectangle())
                        .onTapGesture { tabs.show(surface) }
                    Divider()
                }
            }
            .frame(height: 28)
            Divider()
        }
    }
}
