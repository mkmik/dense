import SwiftUI

// ponytail: folding is per window and forgotten on restart; keep it in the defaults if that annoys.
/// The selected Space's Surfaces placed in the sidebar (placement sidebar), each a section
/// under its title, which folds it. An Extension's (kind ui) is as tall as what it draws, in
/// the system font; a page or a terminal gets a fixed height. The title's menu moves it to
/// the tabs, renames it or closes it.
struct SidebarSections: View {
    let space: Space
    @ObservedObject var tabs: SpaceTabs
    @ObservedObject private var store = SpaceStore.shared
    @State private var folded: Set<String> = []

    var body: some View {
        let sections = space.sidebar(Array(store.surfaces.values))
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        header(section)
                        if !folded.contains(section.id) { content(section) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().frame(height: 1).opacity(0.15) }
        }
    }

    private func header(_ section: Surface) -> some View {
        Button {
            if folded.remove(section.id) == nil { folded.insert(section.id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: folded.contains(section.id) ? "chevron.right" : "chevron.down")
                    .imageScale(.small)
                Text(section.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? section.metadata.name)
                    .font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .contextMenu {
            Button("Move to Tabs") { tabs.place(section, inSidebar: false) }
            Button("Rename…") { tabs.renameTab(section) }
            Divider()
            Button(section.spec.terminal != nil ? "Close…" : "Close", role: .destructive) { tabs.closeTab(section) }
        }
    }

    @ViewBuilder
    private func content(_ section: Surface) -> some View {
        if let owner = section.uiExtension {
            A2UIView(extension: owner, name: section.metadata.name).font(.body)
        } else if let view = tabs.sidebarView(section) {
            // ponytail: one height for all; a height in the Surface's spec if it doesn't suit.
            PageHost(view: view).frame(height: 200)
        } else {
            Text("Waiting for the den…").font(.caption).foregroundStyle(.secondary)
        }
    }
}
