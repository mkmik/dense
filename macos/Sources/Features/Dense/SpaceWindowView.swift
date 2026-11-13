import GhosttyKit
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

    /// The sidebar's width, which its right edge can be dragged to change. Saved for the
    /// next window.
    @AppStorage("dense.sidebarWidth") private var sidebarWidth: Double = 220
    /// The width when the current drag of the sidebar's edge began.
    @State private var dragStartWidth: Double?
    /// Whether the sidebar is folded away, in this window only.
    @State private var sidebarHidden = false

    /// The height of the titlebar row the window buttons sit in.
    static var titlebarHeight: CGFloat { 28 }
    /// Where the sidebar button starts, right of the window buttons.
    private static var sidebarButtonX: CGFloat { 76 }

    init(ghostty: Ghostty.App, tabs: SpaceTabs, @ViewBuilder terminal: () -> Terminal) {
        self.ghostty = ghostty
        self.tabs = tabs
        self.terminal = terminal()
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
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
                    SpaceSidebar(tabs: tabs, selection: ghostty.config.backgroundColor, look: terminalLook)
                }
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                // A grey wash over the terminal background, so the tint follows the theme.
                .background(Color(white: 0.5).opacity(0.15))
                .overlay(alignment: .trailing) { resizeHandle }
                // Above the terminal, which the handle reaches 3 points into.
                .zIndex(1)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // In the titlebar row a drag moves the window, unless the view under
                    // the mouse says no. The tabs say no, so they can be dragged instead.
                    NotWindowDraggable(content: SurfaceTabBar(
                        tabs: tabs,
                        stops: tabs.selected.flatMap { store.spaces[$0] }
                            .map { Space.combos($0.terminals(Array(store.surfaces.values))) }))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                // Clear of the window buttons and the sidebar button.
                .padding(.leading, sidebarHidden ? Self.sidebarButtonX + 22 : 0)
                .frame(height: Self.titlebarHeight)
                if tabs.selected != nil && (tabs.active == nil || tabs.waiting) {
                    VStack(spacing: 12) {
                        Text(placeholder).foregroundStyle(.secondary)
                        if let stopped {
                            // Return opens the confirmation; Return again restarts.
                            Button("Restart Den…") { tabs.restartDen(stopped) }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
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
        .overlay(alignment: .bottomTrailing) { NewBuildPill() }
        .overlay(alignment: .topTrailing) { PreviewPill().frame(height: Self.titlebarHeight) }
        // Over both, so it stays put whether the sidebar is shown or not.
        .overlay(alignment: .topLeading) {
            NotWindowDraggable(content: Button { sidebarHidden.toggle() } label: {
                Image(systemName: "sidebar.left").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(sidebarHidden ? "Show Sidebar" : "Hide Sidebar"))
            .frame(height: Self.titlebarHeight)
            .padding(.leading, Self.sidebarButtonX)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// A strip on the sidebar's right edge, below the titlebar row (where a drag moves the
    /// window), that resizes it. The drag is measured in the window, as the strip moves
    /// along with the mouse.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? sidebarWidth
                    dragStartWidth = start
                    sidebarWidth = min(max(start + value.translation.width, 150), 500)
                }
                .onEnded { _ in dragStartWidth = nil })
            .padding(.top, Self.titlebarHeight)
            .offset(x: 3)
    }

    /// The tab in front, when its den has stopped for good (Exited, Failed or Lost).
    private var stopped: Surface? {
        guard tabs.waiting, let surface = tabs.active.flatMap({ store.surfaces[$0] }),
              let phase = store.den(of: surface)?.status?.phase,
              !["Pending", "Running"].contains(phase) else { return nil }
        return surface
    }

    /// How the terminals draw text.
    private var terminalLook: TerminalLook { TerminalLook(config: ghostty.config, font: tabs.font) }

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
/// selected Space the row is empty.
///
/// A combo's two tabs share one handle, outlined, with a line between the halves; clicking
/// a half brings its tab to the front (t8y:/tabs/combo). A tab, with its combo, can be
/// dragged to another place in the row. With ⌘ held, a tab dropped on another tab is glued
/// beside it, and a tab of a combo dropped away from it is unglued.
private struct SurfaceTabBar: View {
    @ObservedObject var tabs: SpaceTabs
    let stops: [[Surface]]?
    /// The tab being dragged, how far it has moved, where the mouse is, and whether ⌘ is down.
    @State private var drag: Drag?
    /// Where each tab's handle is, to work out where a dragged tab lands. Kept as it was
    /// while a drag moves the handles.
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        HStack(spacing: 2) {
            if let stops {
                let target = glueTarget(stops)
                ForEach(Array(stops.enumerated()), id: \.element[0].id) { index, stop in
                    let dragged = drag.flatMap { d in stop.contains { $0.id == d.id } ? d : nil }
                    HStack(spacing: 0) {
                        ForEach(Array(stop.enumerated()), id: \.element.id) { half, surface in
                            if half > 0 { Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 14) }
                            handle(surface, number: stop.count == 1 ? index + 1 : nil, stop: stop, stops: stops)
                        }
                    }
                    .background(stop.contains { $0.id == tabs.active } && stop.count > 1 ? Color.primary.opacity(0.04) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if stop.count > 1 || target == stop {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(target == stop ? Color.accentColor : Color.primary.opacity(0.2),
                                              lineWidth: target == stop ? 2 : 1)
                        }
                    }
                    // A plain drag takes the whole combo along; ⌘ pulls one half out.
                    .offset(x: dragged.flatMap { $0.glue && stop.count > 1 ? nil : $0.dx } ?? 0)
                    .zIndex(dragged == nil ? 0 : 1)
                }
                Button { tabs.newTab(nil) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Tab")
            }
        }
        // At its full width always: the width the hosting view reports can be a point short,
        // which cut a title or number down to "…".
        .fixedSize()
        .coordinateSpace(name: "tabs")
        .onPreferenceChange(TabFrames.self) { if drag == nil { frames = $0 } }
    }

    /// One tab's handle, or half of a combo's. `number` is its stop's, for a tab not in a combo.
    private func handle(_ surface: Surface, number: Int?, stop: [Surface], stops: [[Surface]]) -> some View {
        let front = surface.id == tabs.active
        return Button { tabs.show(surface) } label: {
            HStack(spacing: 5) {
                // A sparkle for a tab running a coding agent.
                if SpaceStore.shared.den(of: surface)?.agent == true {
                    Image(systemName: "sparkle").imageScale(.small)
                } else {
                    // A bare prompt, no box around it.
                    Text(">_").font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                if let title = Self.title(surface, number: number) { Text(title).lineLimit(1) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(front ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(front ? .primary : .secondary)
        .background(GeometryReader { g in
            Color.clear.preference(key: TabFrames.self, value: [surface.id: g.frame(in: .named("tabs"))])
        })
        .contextMenu {
            Button("Rename Tab…") { tabs.renameTab(surface) }
            if stop.count > 1 {
                Button("Unglue Tab") { tabs.unglue(surface.id) }
            } else if let left = tabs.glueTarget(left: surface.id) {
                Button("Glue to Tab on the Left") { tabs.glue(surface.id, beside: left.id) }
            }
            Divider()
            Button("Close Tab…", role: .destructive) { tabs.closeTab(surface) }
        }
        .offset(x: drag.flatMap { $0.id == surface.id && $0.glue && stop.count > 1 ? $0.dx : nil } ?? 0)
        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("tabs"))
            .onChanged {
                drag = Drag(id: surface.id, dx: $0.translation.width, x: $0.location.x,
                            glue: NSEvent.modifierFlags.contains(.command))
            }
            .onEnded { value in
                drop(surface, stop: stop, stops: stops, at: value.location.x, glue: NSEvent.modifierFlags.contains(.command))
                drag = nil
            })
    }

    /// Where a dragged tab lands. A plain drag moves its stop (the tab, or its combo) to the
    /// mouse. With ⌘, a tab dropped on another tab is glued beside it, and a tab of a combo
    /// dropped away from it is unglued and stays where it is dropped.
    private func drop(_ surface: Surface, stop: [Surface], stops: [[Surface]], at x: CGFloat, glue: Bool) {
        let under = stops.first { over($0, x) }
        if glue && stop.count > 1 {
            guard under != stop else { return }
            let rest = stops.map { $0.filter { $0.id != surface.id } }.filter { $0 != [] }
            tabs.unglue(surface.id, to: rest.filter { mid($0) < x }.count)
        } else if glue, let under, under != stop {
            tabs.glue(surface.id, beside: under[0].id)
        } else {
            tabs.move(surface.id, to: stops.filter { $0 != stop && mid($0) < x }.count)
        }
    }

    /// The stop a ⌘-dragged tab would be glued onto if dropped now: a tab not in a combo, under
    /// the mouse, when the dragged tab is not in a combo either.
    private func glueTarget(_ stops: [[Surface]]) -> [Surface]? {
        guard let drag, drag.glue, stops.contains(where: { $0.count == 1 && $0[0].id == drag.id }) else { return nil }
        return stops.first { $0.count == 1 && $0[0].id != drag.id && over($0, drag.x) }
    }

    /// Where a stop's handle is: its halves together.
    private func span(_ stop: [Surface]) -> CGRect {
        stop.compactMap { frames[$0.id] }.reduce(CGRect.null) { $0.union($1) }
    }

    /// Whether the mouse, at `x`, is over a stop's handle.
    private func over(_ stop: [Surface], _ x: CGFloat) -> Bool {
        let span = span(stop)
        return !span.isNull && span.minX <= x && x <= span.maxX
    }

    /// The middle of a stop's handle.
    private func mid(_ stop: [Surface]) -> CGFloat { span(stop).isNull ? 0 : span(stop).midX }

    /// The Surface's title if it has been given one, else for a tab not in a combo its
    /// number in the row from 1, the number that Go to Tab (⌘1, ⌘2, …) uses. A tab of a
    /// combo without a title shows only its icon.
    private static func title(_ surface: Surface, number: Int?) -> String? {
        surface.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? number.map(String.init)
    }
}

private struct Drag {
    var id: String
    var dx: CGFloat
    var x: CGFloat
    var glue: Bool
}

private struct TabFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
