import AppKit
import SwiftUI

/// A box of the sidebar: a slot under the Space tree that shows the selected Space's
/// Surfaces whose placement is its name (t8y:/tabs/sidebar-boxes). Its height comes from
/// the config (sidebar-box = name:lines) or from dragging its top edge, never from what is
/// in it, so switching Spaces never moves the Space tree.
struct SidebarBox: Equatable {
    var name: String
    /// How tall it is, in lines of the terminal font.
    var lines: Int

    static let defaultLines = 8

    /// The boxes the sidebar shows, top to bottom, whichever Space is selected: one for every
    /// name a Surface uses. Those `listed` in the config come first, in its order; then the
    /// others, by name, at the default height.
    static func shown(_ surfaces: some Sequence<Surface>, listed: [SidebarBox]) -> [SidebarBox] {
        let used = Set(surfaces.compactMap { $0.drawable ? $0.box : nil })
        let others = used.subtracting(listed.map(\.name)).sorted().map { SidebarBox(name: $0, lines: defaultLines) }
        return listed.filter { used.contains($0.name) } + others
    }

    /// The name of a box from what was typed for it. dennet takes a DNS label: lowercased,
    /// with a dash for each run of spaces. Anything else wrong with it, dennet says.
    static func name(typed: String) -> String {
        typed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// The boxes Move to Box offers: those shown, then those listed that nothing uses yet.
    static func choices(shown: [SidebarBox], listed: [SidebarBox]) -> [String] {
        var names = shown.map(\.name)
        for box in listed where !names.contains(box.name) { names.append(box.name) }
        return names
    }
}

// ponytail: folding is per window and forgotten on restart; keep it in the defaults if that annoys.
/// The sidebar's boxes, under the Space tree. Each says its name, which folds it, over the
/// selected Space's Surfaces in it: an Extension's panel scrolls inside the box; a page or
/// a terminal fills it. Several share it evenly. The boxes come before the Space tree when
/// the window is short, down to the tree's minimum (see `SpaceSidebar`).
struct SidebarBoxes: View {
    /// The selected Space, if any.
    let space: Space?
    let boxes: [SidebarBox]
    /// Where Move to Box can send a Surface.
    let choices: [String]
    /// A line of the terminal font.
    let cell: CGSize
    @ObservedObject var tabs: SpaceTabs
    @State private var folded: Set<String> = []

    var body: some View {
        ForEach(boxes, id: \.name) { box in
            BoxView(box: box, space: space, choices: choices, cell: cell, tabs: tabs, folded: .init(
                get: { folded.contains(box.name) },
                set: { if $0 { folded.insert(box.name) } else { folded.remove(box.name) } }))
        }
    }
}

private struct BoxView: View {
    let box: SidebarBox
    let space: Space?
    let choices: [String]
    let cell: CGSize
    @ObservedObject var tabs: SpaceTabs
    @Binding var folded: Bool
    @ObservedObject private var store = SpaceStore.shared

    /// The height its top edge was dragged to, in points, for every window; 0 for the config's.
    @AppStorage private var dragged: Double
    @State private var dragStart: Double?

    init(box: SidebarBox, space: Space?, choices: [String], cell: CGSize, tabs: SpaceTabs, folded: Binding<Bool>) {
        self.box = box
        self.space = space
        self.choices = choices
        self.cell = cell
        self.tabs = tabs
        _folded = folded
        _dragged = AppStorage(wrappedValue: 0, "dense.box.\(box.name).height")
    }

    private var height: CGFloat { dragged > 0 ? dragged : CGFloat(box.lines) * cell.height }

    private var surfaces: [Surface] {
        space.map { $0.surfaces(Array(store.surfaces.values), in: box.name) } ?? []
    }

    var body: some View {
        let surfaces = self.surfaces
        VStack(alignment: .leading, spacing: 4) {
            header(surfaces)
            if !folded {
                content(surfaces)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // As tall as set when there is room; shorter when the window is short.
                    .frame(minHeight: 0, idealHeight: height, maxHeight: height)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { edge }
        .layoutPriority(1)
    }

    private func header(_ surfaces: [Surface]) -> some View {
        Button { folded.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: folded ? "chevron.right" : "chevron.down").imageScale(.small)
                Text(box.name).font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .contextMenu {
            if surfaces.count == 1 {
                actions(surfaces[0])
            } else {
                ForEach(surfaces, id: \.id) { surface in Menu(title(surface)) { actions(surface) } }
            }
            if dragged > 0 {
                Divider()
                Button("Reset Height") { dragged = 0 }
            }
        }
    }

    @ViewBuilder
    private func actions(_ surface: Surface) -> some View {
        Button("Move to Tabs") { tabs.place(surface, in: nil) }
        MoveToBoxMenu(surface: surface, choices: choices, tabs: tabs)
        Button("Rename…") { tabs.renameTab(surface) }
        Divider()
        Button(surface.spec.terminal != nil ? "Close…" : "Close", role: .destructive) { tabs.closeTab(surface) }
    }

    @ViewBuilder
    private func content(_ surfaces: [Surface]) -> some View {
        if surfaces.isEmpty {
            Text(space.map { "Nothing in \(box.name) for \(Self.title($0))" } ?? "Nothing in \(box.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(surfaces, id: \.id) { surface in
                    if surfaces.count > 1 {
                        Text(title(surface)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    entry(surface).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder
    private func entry(_ surface: Surface) -> some View {
        if let owner = surface.uiExtension {
            ScrollView {
                A2UIView(extension: owner, name: surface.metadata.name)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // A new scroll view for each Surface, so a switch shows the top of it.
            .id(surface.id)
        } else if let view = tabs.sidebarView(surface) {
            PageHost(view: view)
        } else {
            Text("Waiting for the den…").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The line over the box, which a drag moves to make the open box taller or shorter. A
    /// double click goes back to the config's height. The drag is measured in the window,
    /// as the line moves along with the mouse.
    private var edge: some View {
        ZStack {
            Rectangle().frame(height: 1).opacity(0.15)
            if !folded {
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? height
                            dragStart = start
                            dragged = max(start - value.translation.height, 2 * cell.height)
                        }
                        .onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { dragged = 0 }
            }
        }
        .frame(height: 7)
        .offset(y: -3)
    }

    private func title(_ surface: Surface) -> String {
        surface.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? surface.metadata.name
    }

    private static func title(_ space: Space) -> String {
        space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name
    }
}

/// Move to Box, on a tab's menu and on a box's: each box but the one the Surface is in, then
/// New Box…, which asks for a name.
struct MoveToBoxMenu: View {
    let surface: Surface
    let choices: [String]
    let tabs: SpaceTabs

    var body: some View {
        Menu("Move to Box") {
            ForEach(choices.filter { $0 != surface.box }, id: \.self) { name in
                Button(name) { tabs.place(surface, in: name) }
            }
            Divider()
            Button("New Box…") { tabs.moveToNewBox(surface) }
        }
    }
}
