import AppKit
import Combine
import Foundation
import GhosttyKit

/// The Space shown in one window, and which of its tabs (Surfaces) is in front.
///
/// The window's terminal area shows one tab at a time by swapping the controller's
/// surface tree; or two side by side, when the tab in front is in a combo with a tab glued
/// beside it (`Space.combos`, t8y:/tabs/combo). Each terminal Surface gets its own Ghostty
/// surface running `den attach`, made the first time the tab is shown while its Den's
/// status says it runs. Until then the tab waits, and attaches as soon as the status
/// changes. Tabs out of view keep running, so switching is instant, but only the terminals of
/// the last few tabs shown (`liveTerminalsKey`, 10 unless set): an older one is freed, and
/// attaches again the next time its tab is shown. The terminal the window opened with is closed as soon as a tab is shown.
///
/// A web Surface's tab shows a `WebPage` instead, beside the terminal area or in its place
/// (`panes`). It too is kept while out of view, and loads its page again when its Surface
/// changes it.
///
/// dense has no macOS window tabs. Ghostty's tab commands (new tab, go to tab, move tab,
/// close tab), from key bindings, menus, AppleScript, Shortcuts or Services, act on these
/// tabs instead. A new tab is a new Den and Surface in dennet; dense does not start the
/// den, whoever runs Dens does.
///
/// The selected Space and each Space's front tab are saved in the user defaults, and a new
/// window opens on them once dennet's lists have loaded.
///
/// A program in a tab can ask for another Space or tab to be shown (`ShowRequest`). The
/// window that does it is the one the user asked from, see `obeys`.
final class SpaceTabs: ObservableObject {
    /// The id of the Space shown, or nil while the window shows its own terminal.
    @Published private(set) var selected: String?

    /// The Surface id of the tab in front, or nil when the Space shows no tab.
    @Published private(set) var active: String?

    /// True while the tab in front has no terminal because its den does not run yet.
    @Published private(set) var waiting = false

    /// The terminals' font, as Ghostty resolved it from the config, once a terminal has
    /// been shown. The sidebar uses it.
    // ponytail: read when a tab is shown, so a font change shows there on the next switch.
    @Published private(set) var font: NSFont?

    private weak var controller: TerminalController?

    /// Each tab's terminal tree, by Surface id. dense makes no splits inside a tab, so each
    /// is one terminal.
    private var trees: [String: SplitTree<Ghostty.SurfaceView>] = [:]

    /// Each web tab's page, by Surface id.
    private var pages: [String: WebPage] = [:]

    /// The tabs in the window: the tab in front and, if it is in a combo, the other one, left
    /// first. The other one's terminal may be missing, while its den doesn't run.
    private var shownCombo: [String] = []

    /// What the window shows, left first: a web tab's page, or nil for the terminal area,
    /// which shows the terminals of the tabs in `shownCombo`. Empty with no tab shown.
    @Published private(set) var panes: [WebPage?] = []

    /// Watches which view has the focus, so clicking into a web page in a combo puts its tab
    /// in front, and clicking back into the terminal puts the terminal's.
    private var focusWatch: NSKeyValueObservation?

    /// Writes how wide the glued tab of the combo in front was dragged, once the drag stops.
    private var pendingWidth: DispatchWorkItem?

    /// How much of the window the left pane of the combo in front takes, as the line between
    /// them shows it, for a combo with a web tab. A terminal combo's is in its split tree.
    @Published var split = 0.5

    /// The tab last in front in each Space, by Space id.
    private var lastTab: [String: String]

    /// The tabs shown in each Space, by Space id, most recent last, so closing tabs one
    /// after another goes back through them in turn.
    private var recent: [String: [String]] = [:]

    /// The tabs shown in this window, by Surface id, oldest first, and which one is where
    /// Go Back and Go Forward (⌘[ and ⌘]) are, as in a browser. Every switch to another tab
    /// counts, in this Space or another.
    // ponytail: never trimmed; a few bytes per switch.
    private var history: [String] = []
    private var historyIndex = -1

    /// Text to type into a new tab once it is attached, by Surface id.
    private var pendingInput: [String: String] = [:]

    /// Watches for each tab's den attach exiting, by Surface id.
    private var exits: [String: AnyCancellable] = [:]

    /// The tabs with a terminal, by Surface id, the one shown longest ago first.
    private var used: [String] = []

    /// How many terminals a window keeps (`used`): each costs some 30 MB, mostly of GPU
    /// memory. Unset or 0 means 10. Set with
    /// `defaults write pub.mkm.dense dense.liveTerminals -int 5`.
    static let liveTerminalsKey = "dense.liveTerminals"

    private var restore: AnyCancellable?
    private var denChanges: AnyCancellable?
    private var surfaceChanges: AnyCancellable?

    /// When a key was last pressed in this window.
    private var lastKey = Date.distantPast
    private var keyMonitor: Any?
    private var showRequests: AnyCancellable?
    /// A request obeyed whose Space or tab dennet hasn't sent yet, and until when to wait.
    private var pendingShow: (request: ShowRequest, until: Date)?
    private var pendingChanges: AnyCancellable?

    private static let selectedKey = "dense.selectedSpace"
    private static let lastTabKey = "dense.lastTab"

    init(controller: TerminalController) {
        self.controller = controller
        let defaults = UserDefaults.standard
        lastTab = defaults.dictionary(forKey: Self.lastTabKey) as? [String: String] ?? [:]

        // Show the saved Space right away (no terminal yet, so the window's own terminal
        // doesn't flash), and its tab once the lists of its machine are in. A Host's lists
        // come after this machine's, so once this machine's are in, the window's own
        // terminal is dropped and the window stays blank until the Space turns up. It
        // stays blank if the Space never does, until another Space is picked.
        let saved = defaults.string(forKey: Self.selectedKey)
        selected = saved
        let store = SpaceStore.shared
        restore = store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, store.loaded else { return }
            // Nothing was saved, or another Space has been picked since.
            guard let saved, self.selected == saved else { return self.restore = nil }
            if let space = store.spaces[saved], space.spec.archived != true, store.loaded(space) {
                self.restore = nil
                self.select(space)
            } else if self.active == nil, self.controller?.surfaceTree.isEmpty == false {
                self.show(nil)
            }
        }

        // A waiting tab, or the tab glued to the one in front, attaches as soon as its den runs.
        denChanges = store.$dens.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let surface = self.active.flatMap({ store.surfaces[$0] }),
                  self.combo(of: surface).contains(where: { self.trees[$0.id] == nil && store.den(of: $0)?.running == true })
            else { return }
            self.show(surface)
        }

        // A combo glued or unglued, from this window or elsewhere, changes what is shown. A
        // web tab whose page changed loads it again; one whose Surface has gone drops it.
        surfaceChanges = store.$surfaces.receive(on: DispatchQueue.main).sink { [weak self] surfaces in
            guard let self else { return }
            for (id, page) in self.pages {
                if let web = surfaces[id]?.spec.web {
                    if web != page.spec { page.load(web) }
                } else if !self.shownCombo.contains(id) {
                    self.pages[id] = nil
                }
            }
            guard let surface = self.active.flatMap({ surfaces[$0] }),
                  self.combo(of: surface).map(\.id) != self.shownCombo else { return }
            self.show(surface)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, let window = event.window, window === self.controller?.window { self.lastKey = Date() }
            return event
        }
        showRequests = store.showRequests.receive(on: DispatchQueue.main).sink { [weak self] request in
            guard let self, SpaceTabs.obeys(request, active: self.active, lastKey: self.lastKey) else { return }
            self.pendingShow = nil
            if !self.go(to: request) { self.pendingShow = (request, Date() + 10) }
        }
        pendingChanges = store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let pending = self.pendingShow else { return }
            if Date() > pending.until || self.go(to: pending.request) { self.pendingShow = nil }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Whether this window does what a `ShowRequest` asks: the request comes from the tab in
    /// front here, and a key was pressed here a moment ago. That is the window whose key press
    /// made the program ask, which is the same window den gives the terminal's size to: the
    /// one last typed into. Other windows showing that tab, here or on another machine, stay.
    static func obeys(_ request: ShowRequest, active: String?, lastKey: Date, now: Date = Date()) -> Bool {
        request.from == active && now.timeIntervalSince(lastKey) < 5
    }

    /// Shows what a request asks for. False while dennet hasn't sent it yet.
    private func go(to request: ShowRequest) -> Bool {
        let store = SpaceStore.shared
        if let id = request.surface {
            return show(surfaceID: id)
        } else if let id = request.space {
            guard let space = store.spaces[id] else { return false }
            select(space)
        }
        return true
    }

    /// Shows a tab by its Surface id, in whichever Space it is. False if dennet has no such tab.
    private func show(surfaceID id: String) -> Bool {
        let store = SpaceStore.shared
        guard let surface = store.surfaces[id],
              let space = store.spaces[objectID(surface.metadata.namespace, surface.spec.space)] else { return false }
        selected = space.id
        show(surface)
        return true
    }

    /// Go Back, or Go Forward: shows the tab before (or after) the current one in the history,
    /// skipping tabs deleted since. False when there is none.
    func goHistory(forward: Bool) -> Bool {
        var index = historyIndex
        while true {
            index += forward ? 1 : -1
            guard history.indices.contains(index) else { return false }
            guard !sameStop(history[index], active), SpaceStore.shared.surfaces[history[index]] != nil else { continue }
            historyIndex = index
            return show(surfaceID: history[index])
        }
    }

    /// The selected Space's tabs, in order.
    var tabs: [Surface] {
        guard let selected, let space = SpaceStore.shared.spaces[selected] else { return [] }
        return space.tabs(Array(SpaceStore.shared.surfaces.values))
    }

    /// The selected Space's tabs as stops: a tab alone, or a combo (see `Space.combos`).
    var stops: [[Surface]] { Space.combos(tabs) }

    /// The stop a tab is in, in its own Space: the tab alone, or its combo.
    func combo(of surface: Surface) -> [Surface] {
        let store = SpaceStore.shared
        guard let space = store.spaces[objectID(surface.metadata.namespace, surface.spec.space)] else { return [surface] }
        return Space.combos(space.tabs(Array(store.surfaces.values))).first { $0.contains { $0.id == surface.id } }
            ?? [surface]
    }

    /// Whether two tabs are the same stop: the same tab, or the two tabs of a combo.
    private func sameStop(_ a: String, _ b: String?) -> Bool {
        a == b || SpaceStore.shared.surfaces[a].map(combo(of:))?.contains { $0.id == b } == true
    }

    func select(_ space: Space) {
        selected = space.id
        show(tabs.first { $0.id == lastTab[space.id] } ?? tabs.first)
    }

    /// Brings a tab of the selected Space to the front; nil shows no tab. A tab in a combo
    /// comes with the other tab, side by side.
    func show(_ surface: Surface?) {
        guard let controller else { return }

        // Keep how wide the panes of the combo in front were dragged, if not yet written.
        if let pendingWidth { pendingWidth.perform(); pendingWidth.cancel() }

        noteShown(surface)

        // Each tab's terminal, or page. A terminal whose den attach has exited is attached
        // again, if its den runs. The window's own terminal, shown before any tab, is dropped.
        let members = surface.map(combo(of:)) ?? []
        shownCombo = members.map(\.id)
        for tab in members {
            if let web = tab.spec.web {
                if pages[tab.id] == nil {
                    let page = WebPage(web)
                    let id = tab.id
                    page.change = { [weak self] in self?.changePage(id) }
                    pages[tab.id] = page
                }
                continue
            }
            trees[tab.id] = trees[tab.id].flatMap { $0.allSatisfy(\.processExited) ? nil : $0 }
            if trees[tab.id] == nil, SpaceStore.shared.den(of: tab)?.running == true {
                trees[tab.id] = SplitTree(view: makeView(tab, controller: controller))
            }
        }
        keepLive(members.map(\.id).filter { trees[$0] != nil })
        watchFocus(controller)
        guard let surface, trees[surface.id] != nil || pages[surface.id] != nil else {
            waiting = surface != nil
            panes = []
            controller.surfaceTree = .init()
            return
        }
        waiting = false
        let shownTabs = members.filter { trees[$0.id] != nil || pages[$0.id] != nil }
        let newPanes = shownTabs.map { pages[$0.id] }
        // How wide the glued tab was dragged, kept with the bond in dennet.
        let ratio = members.count == 2 ? members[1].spec.width.map { 1 - Double($0) / 100 } ?? 0.5 : 0.5
        if !newPanes.elementsEqual(panes, by: ===) {
            panes = newPanes
            split = ratio
        }
        let roots = members.compactMap { trees[$0.id]?.root }
        let shown = roots.count < 2 ? members.lazy.compactMap { self.trees[$0.id] }.first ?? .init() : SplitTree(
            root: .split(.init(direction: .horizontal, ratio: ratio, left: roots[0], right: roots[1])),
            zoomed: nil)
        let old = controller.focusedSurface
        // Moving between the two tabs of a combo only moves the focus.
        if !shown.elementsEqual(controller.surfaceTree, by: ===) { controller.surfaceTree = shown }
        if let page = pages[surface.id] {
            page.focus()
        } else if let view = trees[surface.id]?.root?.leftmostLeaf() {
            DispatchQueue.main.async { Ghostty.moveFocus(to: view, from: old) }
            if let surface = view.surface, let raw = ghostty_surface_quicklook_font(surface) {
                // A copy of the CTFont, which is ours to release.
                let ctFont = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
                if font != ctFont as NSFont { font = ctFont as NSFont }
            }
        }
    }

    // ponytail: another window showing the same combo picks the width up on its next switch.
    /// The window's terminals changed. If the line between the panes of a terminal combo
    /// was dragged, the width is kept with the bond. See `dragged(to:)`.
    func treeChanged(_ tree: SplitTree<Ghostty.SurfaceView>) {
        if case let .split(split) = tree.root { dragged(to: split.ratio) }
    }

    /// The line between the panes of the combo in front is at `ratio` of the window, from the
    /// left: the glued tab's `width` is written to dennet once the drag stops.
    func dragged(to ratio: Double) {
        guard shownCombo.count == 2, let glued = SpaceStore.shared.surfaces[shownCombo[1]] else { return }
        let width = Int32(min(max(((1 - ratio) * 100).rounded(), 1), 99))
        pendingWidth?.cancel()
        pendingWidth = nil
        guard width != glued.spec.width ?? 50 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWidth = nil
            Task { @MainActor in
                _ = await self?.patchSpec("surfaces", glued.metadata, ["width": width], failure: "Could not keep the width")
            }
        }
        pendingWidth = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Puts a tab in front in the history and in its Space's last and recent tabs.
    /// Notes the tabs in front as the ones shown last, and frees the terminals of the tabs
    /// shown longest ago, over `liveTerminalsKey`. Their dens keep running; den attach just
    /// exits, and the tab attaches again when shown.
    private func keepLive(_ shown: [String]) {
        used.removeAll { shown.contains($0) || trees[$0] == nil }
        used += shown
        let setting = UserDefaults.standard.integer(forKey: Self.liveTerminalsKey)
        while used.count > max(setting > 0 ? setting : 10, shown.count) {
            let id = used.removeFirst()
            // The watch first: den attach exiting here must not close the tab.
            exits[id] = nil
            trees[id] = nil
        }
    }

    private func noteShown(_ surface: Surface?) {
        active = surface?.id
        // A new place in the history, unless this is the place Go Back or Go Forward moved to.
        // A combo is one place: moving between its tabs changes which one it brings back.
        if let id = surface?.id, historyIndex < 0 || history[historyIndex] != id {
            if historyIndex >= 0, sameStop(history[historyIndex], id) {
                history[historyIndex] = id
            } else {
                history.removeSubrange((historyIndex + 1)...)
                history.append(id)
                historyIndex = history.count - 1
            }
        }
        if let selected, let surface {
            lastTab[selected] = surface.id
            recent[selected, default: []].removeAll { $0 == surface.id }
            recent[selected, default: []].append(surface.id)
        }
        UserDefaults.standard.set(selected, forKey: Self.selectedKey)
        UserDefaults.standard.set(lastTab, forKey: Self.lastTabKey)
    }

    /// The focus moved to a terminal in the window. In a combo, its tab comes to the front.
    func focused(_ view: Ghostty.SurfaceView?) {
        guard let view, let id = shownCombo.first(where: { trees[$0]?.contains(view) == true }), id != active,
              let surface = SpaceStore.shared.surfaces[id] else { return }
        noteShown(surface)
    }

    /// Starts watching the window's first responder, once it has a window. A page, or a view
    /// inside a terminal, taking the focus puts its tab in front, as in `focused(_:)`, which
    /// sees only terminals.
    private func watchFocus(_ controller: TerminalController) {
        guard focusWatch == nil, let window = controller.window else { return }
        focusWatch = window.observe(\.firstResponder) { [weak self] window, _ in
            DispatchQueue.main.async {
                guard let self, let view = window.firstResponder as? NSView,
                      let id = self.shownCombo.first(where: { id in
                          self.pages[id].map { view.isDescendant(of: $0.view) }
                              ?? self.trees[id]?.contains { view.isDescendant(of: $0) } == true
                      }),
                      id != self.active, let surface = SpaceStore.shared.surfaces[id] else { return }
                self.noteShown(surface)
            }
        }
    }

    /// Whether the tab in front is a web tab.
    var activeIsWeb: Bool { active.map { pages[$0] != nil } ?? false }

    /// Called when the tab in front is to close: the user closed it (File > Close Tab). If
    /// there is a tab in front this returns true, and otherwise false, so the window closes
    /// as usual. See `close(_:ask:)`.
    func closeActiveTab(ask: Bool) -> Bool {
        guard let closing = active else { return false }
        close(tab: closing, ask: ask)
        return true
    }

    /// Called when a terminal in the window is to close: the user closed it (⌘W), or its
    /// den attach exited. `node` is a tab's terminal, or all the window shows, which closes
    /// the tab in front. Returns false when it is no tab's, so it closes as usual.
    func close(_ node: SplitTree<Ghostty.SurfaceView>.Node, ask: Bool) -> Bool {
        guard let id = shownCombo.first(where: { trees[$0]?.root == node })
                ?? (node == controller?.surfaceTree.root ? active : nil) else { return false }
        close(tab: id, ask: ask)
        return true
    }

    /// With `ask`, the user closed the tab: it asks, as the tab's menu does, whether to close
    /// it or detach from it. Without, den attach exited on its own (the den stopped, or the
    /// connection to it broke), so only the terminal goes: the tab stays, shows why its den
    /// isn't running, or attaches again when clicked.
    private func close(tab closing: String, ask: Bool) {
        if ask {
            if let surface = SpaceStore.shared.surfaces[closing] { closeTab(surface) }
            return
        }
        trees[closing] = nil
        guard closing == active else {
            // The other tab of the combo in front: the tab in front fills the window.
            controller?.surfaceTree = active.flatMap { trees[$0] } ?? .init()
            if controller?.surfaceTree.isEmpty == true { panes.removeAll { $0 == nil } }
            return
        }
        let next = tab(after: closing)
        active = nil
        show(next)
    }

    /// The tab to show once `closing` goes: the one shown before it that is still there;
    /// else the one left of it, else the first. It is forgotten as shown.
    private func tab(after closing: String) -> Surface? {
        let rest = tabs.filter { $0.id != closing }
        guard let selected else { return rest.first }
        recent[selected]?.removeAll { $0 == closing }
        // The other tab of its combo, which shared its place.
        if shownCombo.contains(closing), let other = rest.first(where: { $0.id != closing && shownCombo.contains($0.id) }) {
            return other
        }
        if let id = recent[selected]?.last(where: { id in rest.contains { $0.id == id } }) {
            return rest.first { $0.id == id }
        }
        let index = tabs.firstIndex { $0.id == closing } ?? 0
        return index > 0 ? tabs[index - 1] : rest.first
    }

    /// Makes a new tab at the end of the selected Space: a Den and a Surface in dennet, then
    /// shows it. The tab waits until the den runs. `config` is what Ghostty asks of a new
    /// tab: working directory, command, environment, or text to type.
    func newTab(_ config: Ghostty.SurfaceConfiguration?) {
        guard let selected, let space = SpaceStore.shared.spaces[selected] else {
            NSSound.beep()
            return
        }
        let namespace = space.metadata.namespace ?? "default"
        let order = (tabs.compactMap(\.spec.order).max() ?? 0) + 10

        var den: [String: Any] = [
            // The Space's directory first, so a new tab starts there and not wherever the
            // tab it was made from has cd'd to.
            // ponytail: this also wins over a folder Ghostty asks for (Services "New Tab
            // Here"); tell them apart if that comes up.
            "workingDir": Space.workingDir(of: space, in: SpaceStore.shared.spaces)
                ?? config?.workingDirectory ?? controller?.focusedSurface?.pwd ?? NSHomeDirectory(),
            "inheritEnv": ["LANG", "LC_*", "SSH_AUTH_SOCK", "TMPDIR"],
        ]
        if let command = config?.command, !command.isEmpty {
            // Ghostty runs a command through a shell, so the Den does too.
            den["command"] = [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "-l", "-c", command]
        }
        if let env = config?.environmentVariables, !env.isEmpty {
            den["env"] = env.map { ["name": $0.key, "value": $0.value] }
        }

        Task { @MainActor in
            do {
                let store = SpaceStore.shared
                let created: Created = try await store.create(
                    "dens", kind: "Den", namespace: namespace,
                    metadata: ["generateName": "\(space.metadata.name)-"], spec: den)
                let name = created.metadata.name
                let surface: Surface = try await store.create(
                    "surfaces", kind: "Surface", namespace: namespace,
                    metadata: ["name": name],
                    spec: ["space": space.metadata.name, "order": order, "kind": "terminal", "terminal": ["den": name]])
                if let input = config?.initialInput { pendingInput[surface.id] = input }
                if self.selected == space.id { self.show(surface) }
            } catch {
                self.alert("Could not make a new tab", error)
            }
        }
    }

    /// Asks for an address and a title and makes a web tab in the selected Space: a browser
    /// with `navigation`, else a tab that shows only that page. With `beside`, a tab not in a
    /// combo, the new tab is glued on its right; else it goes at the end. Then shows it.
    func newWebTab(navigation: Bool, beside main: Surface? = nil) {
        guard let selected, let space = SpaceStore.shared.spaces[selected] else { return NSSound.beep() }
        // Right after the tab it is glued to, so it stays there when unglued.
        let order = main.map { ($0.spec.order ?? 0) + 1 } ?? (tabs.compactMap(\.spec.order).max() ?? 0) + 10
        askWebPage(navigation ? "New Browser Tab" : "New Web Page Tab", button: "Open") { url, title in
            var spec: [String: Any] = ["space": space.metadata.name, "order": order, "kind": "web",
                                       "web": ["url": url.absoluteString, "navigation": navigation]]
            if !title.isEmpty { spec["title"] = title }
            if let main { spec["beside"] = main.metadata.name }
            Task { @MainActor in
                do {
                    // A `beside` left on the tab glued onto would keep this from counting (see glue).
                    if let main, main.spec.beside != nil,
                       await !self.patchSpec("surfaces", main.metadata, ["beside": NSNull()], failure: "Could not glue the tab") { return }
                    let surface: Surface = try await SpaceStore.shared.create(
                        "surfaces", kind: "Surface", namespace: space.metadata.namespace ?? "default",
                        metadata: ["generateName": "\(space.metadata.name)-"], spec: spec)
                    if self.selected == space.id { self.show(surface) }
                } catch {
                    self.alert("Could not make a new tab", error)
                }
            }
        }
    }

    /// Asks for another page, and title, for a web tab and writes them to its Surface; the
    /// tab then shows the new page.
    func changePage(_ id: String) {
        guard let surface = SpaceStore.shared.surfaces[id], let web = surface.spec.web else { return NSSound.beep() }
        let current = web.html != nil ? nil : web.url.flatMap(URL.init(string:)).map { $0.isFileURL ? $0.path : $0.absoluteString }
        askWebPage("Change Page", address: current, title: surface.spec.title, button: "Open") { url, title in
            Task { @MainActor in
                await self.patchSpec("surfaces", surface.metadata,
                                     ["web": ["url": url.absoluteString, "html": NSNull()],
                                      "title": title.isEmpty ? NSNull() : title],
                                     failure: "Could not change the page")
            }
        }
    }

    /// Asks in a sheet for a web page's address (or a file's path) and a title, which may be
    /// empty. Passes on the address's URL and the trimmed title.
    private func askWebPage(
        _ message: String, address: String? = nil, title: String? = nil, button: String,
        then done: @escaping (URL, String) -> Void
    ) {
        let addressField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        addressField.stringValue = address ?? ""
        addressField.placeholderString = "Address, or a file's path"
        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        titleField.stringValue = title ?? ""
        titleField.placeholderString = "Title (optional)"
        addressField.nextKeyView = titleField
        titleField.nextKeyView = addressField
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        box.addSubview(addressField)
        box.addSubview(titleField)

        let alert = NSAlert()
        alert.messageText = message
        alert.accessoryView = box
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = addressField

        let open = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            guard let url = WebPage.url(addressField.stringValue) else { return NSSound.beep() }
            done(url, titleField.stringValue.trimmingCharacters(in: .whitespaces))
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(alert.runModal())
        }
    }

    /// Asks for a title and makes a new Space in dennet, under `parent` or at the top
    /// level, after its siblings. Then shows it.
    func newSpace(parent: Space?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Title"
        let alert = NSAlert()
        alert.messageText = parent == nil ? "New Space" : "New Subspace"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let create = { [weak self] (response: NSApplication.ModalResponse) in
            let title = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !title.isEmpty else { return }
            let namespace = parent?.metadata.namespace ?? "default"
            let siblings = SpaceStore.shared.spaces.values.filter {
                $0.metadata.namespace ?? "default" == namespace && $0.spec.parent == parent?.metadata.name
            }
            var spec: [String: Any] = ["title": title, "order": (siblings.compactMap(\.spec.order).max() ?? 0) + 10]
            if let parent { spec["parent"] = parent.metadata.name }

            Task { @MainActor in
                do {
                    let space: Space = try await SpaceStore.shared.create(
                        "spaces", kind: "Space", namespace: namespace,
                        metadata: ["generateName": "space-"], spec: spec)
                    self.select(space)
                } catch {
                    self.alert("Could not make a new Space", error)
                }
            }
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: create)
        } else {
            create(alert.runModal())
        }
    }

    /// Asks for a new title and writes it to the Space in dennet.
    func renameSpace(_ space: Space) {
        askTitle("Rename Space", space.spec.title) { title in
            guard !title.isEmpty else { return }
            self.setTitle(title, of: "spaces", space.metadata, failure: "Could not rename the Space")
        }
    }

    /// Asks for a new title for a tab and writes it to its Surface in dennet. An empty
    /// title removes it, and the tab shows its number again.
    func renameTab(_ surface: Surface) {
        askTitle("Rename Tab", surface.spec.title, placeholder: "Title (empty shows the tab's number)") { title in
            self.setTitle(title.isEmpty ? nil : title, of: "surfaces", surface.metadata, failure: "Could not rename the tab")
        }
    }

    /// Asks in a sheet for a title, starting from `current`, and passes it on trimmed if it
    /// changed.
    private func askTitle(
        _ message: String, _ current: String?, placeholder: String = "Title", button: String = "Rename",
        then done: @escaping (String) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = placeholder
        let alert = NSAlert()
        alert.messageText = message
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let rename = { (response: NSApplication.ModalResponse) in
            let title = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, title != current ?? "" else { return }
            done(title)
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: rename)
        } else {
            rename(alert.runModal())
        }
    }

    /// Sets, or with nil removes, spec.title of a Space or Surface in dennet.
    private func setTitle(_ title: String?, of resource: String, _ meta: ObjectMeta, failure: String) {
        Task { @MainActor in await self.patchSpec(resource, meta, ["title": title as Any? ?? NSNull()], failure: failure) }
    }

    /// Merges fields into the spec of a Space or Surface in dennet; NSNull removes one. If
    /// dennet refuses, it says why, under `failure`, and returns false.
    @MainActor @discardableResult
    private func patchSpec(_ resource: String, _ meta: ObjectMeta, _ spec: [String: Any], failure: String) async -> Bool {
        let path = "/apis/den.mkm.pub/v1alpha1/namespaces/\(meta.namespace ?? "default")/\(resource)/\(meta.name)"
        do {
            _ = try await SpaceStore.shared.request(
                "PATCH", path, json: ["spec": spec], contentType: "application/merge-patch+json")
            return true
        } catch {
            alert(failure, error)
            return false
        }
    }

    /// Edits a Space's tags in a token field, as Finder's Tags field does: each tag is a
    /// token, typed tags are completed from the tags other Spaces have, and comma, space
    /// or Return ends a tag. A leading "#" is dropped, as the filter adds it.
    func editTags(_ space: Space) {
        let field = NSTokenField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.objectValue = space.spec.tags ?? []
        field.placeholderString = "Add tags"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ", ").union(.newlines)
        let completions = TagCompletions(SpaceStore.shared.spaces.values.flatMap { $0.spec.tags ?? [] })
        field.delegate = completions

        let alert = NSAlert()
        alert.messageText = "Tags of \"\(space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name)\""
        alert.informativeText = "Filter the sidebar by a tag with #tag."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let save = { [weak self] (response: NSApplication.ModalResponse) in
            _ = completions // Kept until the sheet is done: the field holds its delegate weakly.
            guard let self, response == .alertFirstButtonReturn else { return }
            // Unique and not empty, as dennet requires; in the order typed.
            var seen = Set<String>()
            let tags = (field.objectValue as? [String] ?? [])
                .map { String($0.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard tags != space.spec.tags ?? [] else { return }
            let path = "/apis/den.mkm.pub/v1alpha1/namespaces/\(space.metadata.namespace ?? "default")/spaces/\(space.metadata.name)"
            Task { @MainActor in
                do {
                    _ = try await SpaceStore.shared.request(
                        "PATCH", path, json: ["spec": ["tags": tags.isEmpty ? NSNull() : tags as Any]],
                        contentType: "application/merge-patch+json")
                } catch {
                    self.alert("Could not save the tags", error)
                }
            }
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(alert.runModal())
        }
    }

    /// The user default behind the archive sheet's checkbox: archive the subspaces too
    /// (true, the default) or delete them.
    static let archiveSubspacesKey = "dense.archiveSubspaces"

    /// Asks, in a sheet like Ghostty's close confirmations, then deletes a Space from
    /// dennet with its subspaces, their tabs (Surfaces) and the Dens those attach to, which
    /// ends their terminal sessions. dennet does not delete dependent objects itself.
    func deleteSpace(_ space: Space) { remove(space, archive: false) }

    /// Like `deleteSpace`, but the Space itself stays in dennet, archived: hidden from the
    /// sidebar and listed in Open Space (⌘K), which brings it back (`unarchiveSpace`). Its
    /// tabs go all the same. A checkbox in the sheet, remembered for next time, says whether
    /// its subspaces are archived too or deleted.
    func archiveSpace(_ space: Space) { remove(space, archive: true) }

    private func remove(_ space: Space, archive: Bool) {
        let store = SpaceStore.shared
        let namespace = space.metadata.namespace ?? "default"

        // The Space and everything under it, parents first. The seen check stops at
        // parents that form a loop.
        var doomed = [space]
        var seen: Set = [space.id]
        var i = 0
        while i < doomed.count {
            let parent = doomed[i]
            doomed += store.spaces.values.filter {
                $0.metadata.namespace == parent.metadata.namespace && $0.spec.parent == parent.metadata.name
                    && seen.insert($0.id).inserted
            }
            i += 1
        }
        let surfaces = doomed.flatMap { $0.tabs(Array(store.surfaces.values)) }
        let ids = seen
        let subspaces = doomed.count - 1

        let alert = NSAlert()
        let title = space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name
        if archive {
            alert.messageText = "Archive \"\(title)\"?"
            alert.informativeText = (surfaces.isEmpty ? "" : "Its tabs will be closed, and their terminal sessions terminated. ")
                + "Open Space (⌘K) brings it back, with a new tab."
            // NSAlert's own checkbox, under the text. Shown, greyed out, even with no
            // subspaces, so the choice is always in view.
            alert.showsSuppressionButton = true
            alert.suppressionButton?.isEnabled = subspaces > 0
            alert.suppressionButton?.title = switch subspaces {
            case 0: "Archive subspaces too (unchecked deletes them)"
            case 1: "Archive its subspace too (unchecked deletes it)"
            default: "Archive its \(subspaces) subspaces too (unchecked deletes them)"
            }
            let keep = UserDefaults.standard.object(forKey: Self.archiveSubspacesKey) as? Bool ?? true
            alert.suppressionButton?.state = keep ? .on : .off
            alert.addButton(withTitle: "Archive")
        } else {
            alert.messageText = "Delete \"\(title)\"?"
            var gone: [String] = []
            if subspaces > 0 { gone.append(subspaces == 1 ? "1 subspace" : "\(subspaces) subspaces") }
            if !surfaces.isEmpty { gone.append(surfaces.count == 1 ? "1 tab" : "\(surfaces.count) tabs") }
            alert.informativeText = gone.isEmpty
                ? "This cannot be undone."
                : "Its \(gone.joined(separator: " and ")) will be deleted too, and their terminal sessions will be terminated."
            alert.addButton(withTitle: "Delete")
        }
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let confirm = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertFirstButtonReturn else { return }
            // As in Ghostty: keeps focus right when Stage Manager is used (#8336).
            alert.window.orderOut(nil)
            let keepSubspaces = alert.suppressionButton?.state == .on
            if archive { UserDefaults.standard.set(keepSubspaces, forKey: Self.archiveSubspacesKey) }

            Task { @MainActor in
                let root = "/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)"
                do {
                    // dennet would close an archived Space's tabs too, but this also drops
                    // their terminals here.
                    for surface in surfaces { try await self.delete(surface) }
                    // Children first, so no subspace shows at the top level for a moment.
                    // dennet archives the subspaces of an archived Space too, but later.
                    for gone in doomed.reversed() {
                        let path = "\(root)/spaces/\(gone.metadata.name)"
                        if archive && (gone.id == space.id || keepSubspaces) {
                            _ = try await store.request(
                                "PATCH", path, json: ["spec": ["archived": true]], contentType: "application/merge-patch+json")
                        } else {
                            _ = try await store.request("DELETE", path)
                        }
                    }
                } catch {
                    self.alert(archive ? "Could not archive the Space" : "Could not delete the Space", error)
                    return
                }
                // Move off the Space, dropping its tab in front. dennet's watch may not
                // have reported the changes yet.
                guard let selected = self.selected, ids.contains(selected) else { return }
                self.active = nil
                if let next = Space.rows(store.spaces.values.filter { !ids.contains($0.id) && $0.spec.archived != true }).first {
                    self.select(next.space)
                } else {
                    self.selected = nil
                    self.show(nil)
                }
            }
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    /// Brings back an archived Space, from Open Space (⌘K): dennet reopens it, and it is
    /// shown with one new tab. The Spaces under it stay archived. Archived Spaces above it
    /// come back too, without tabs, top first: dennet archives again any Space whose
    /// parent is archived.
    func unarchiveSpace(_ space: Space) {
        let store = SpaceStore.shared
        var chain = [space]
        while let name = chain[0].spec.parent, let up = store.spaces[objectID(space.metadata.namespace, name)],
              up.spec.archived == true, !chain.contains(where: { $0.id == up.id }) {
            chain.insert(up, at: 0)
        }
        let root = "/apis/den.mkm.pub/v1alpha1/namespaces/\(space.metadata.namespace ?? "default")"
        Task { @MainActor in
            do {
                for up in chain {
                    _ = try await store.request(
                        "PATCH", "\(root)/spaces/\(up.metadata.name)", json: ["spec": ["archived": NSNull()]],
                        contentType: "application/merge-patch+json")
                }
            } catch {
                self.alert("Could not bring back the Space", error)
                return
            }
            self.select(space)
            self.newTab(nil)
        }
    }

    /// Asks whether to close the tab, deleting its Surface and Den in dennet, which ends its
    /// den; or to detach, deleting only the Surface, so the den runs on without a tab. If
    /// it was in front, the next tab is shown. A web tab has no den, and closes without
    /// asking, as a browser's tab does.
    func closeTab(_ surface: Surface) {
        guard surface.spec.web == nil else { return drop(surface, keepDen: true) }
        let alert = NSAlert()
        alert.messageText = "Close Tab?"
        alert.informativeText = "Close ends the den and the program running in it. "
            + "Detach removes the tab but leaves the den running, for den attach to reach later."
        alert.addButton(withTitle: "Close").hasDestructiveAction = true
        alert.addButton(withTitle: "Detach")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let close = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            alert.window.orderOut(nil)
            self.drop(surface, keepDen: response == .alertSecondButtonReturn)
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: close)
        } else {
            close(alert.runModal())
        }
    }

    /// Deletes a tab (see `delete`) and, if it was in front, shows the next one.
    private func drop(_ surface: Surface, keepDen: Bool) {
        Task { @MainActor in
            do {
                try await self.delete(surface, keepDen: keepDen)
            } catch {
                self.alert("Could not close the tab", error)
                return
            }
            guard self.active == surface.id else {
                if let selected = self.selected { self.recent[selected]?.removeAll { $0 == surface.id } }
                return
            }
            // dennet's watch may not have reported the delete yet; tab(after:) leaves
            // the tab out either way.
            let next = self.tab(after: surface.id)
            self.active = nil
            self.show(next)
        }
    }

    /// Asks, then makes the tab's Den again with the same name and spec, so dennet starts
    /// a new den for it and the tab attaches once it runs. For a den that has stopped.
    func restartDen(_ surface: Surface) {
        guard let den = SpaceStore.shared.den(of: surface) else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Restart the den?"
        alert.informativeText = "A new den starts with the same settings. What ran in the old one is gone."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")

        let restart = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertFirstButtonReturn else { return }
            alert.window.orderOut(nil)
            Task { @MainActor in
                do {
                    try await Self.recreate(den)
                } catch {
                    self.alert("Could not restart the den", error)
                }
            }
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: restart)
        } else {
            restart(alert.runModal())
        }
    }

    /// Deletes a Den and creates it again from its own spec, labels and annotations. The
    /// name has to be free first: dennet keeps a Den until its den has stopped, which for
    /// a lost den can take a Lease term (30 s).
    @MainActor
    private static func recreate(_ den: Den) async throws {
        let store = SpaceStore.shared
        let namespace = den.metadata.namespace ?? "default"
        let path = "/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)/dens/\(den.metadata.name)"
        let old = try JSONSerialization.jsonObject(with: try await store.request("GET", path)) as? [String: Any]
        let oldMeta = old?["metadata"] as? [String: Any] ?? [:]
        var metadata: [String: Any] = ["name": den.metadata.name]
        for key in ["labels", "annotations"] { metadata[key] = oldMeta[key] }

        _ = try await store.request("DELETE", path)
        let deadline = Date.now.addingTimeInterval(40)
        while true {
            do {
                _ = try await store.request("GET", path)
            } catch let error as SpaceStore.RequestError where error.message.contains("not found") {
                break
            }
            guard Date.now < deadline else {
                throw SpaceStore.RequestError(message: "The old den has not stopped yet. Try again in a moment.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let _: Created = try await store.create(
            "dens", kind: "Den", namespace: namespace, metadata: metadata,
            spec: old?["spec"] as? [String: Any] ?? [:])
    }

    /// Deletes a tab's Surface, and its Den in dennet unless `keepDen`, and drops its
    /// terminal or page.
    @MainActor
    private func delete(_ surface: Surface, keepDen: Bool = false) async throws {
        let store = SpaceStore.shared
        let root = "/apis/den.mkm.pub/v1alpha1/namespaces/\(surface.metadata.namespace ?? "default")"
        _ = try await store.request("DELETE", "\(root)/surfaces/\(surface.metadata.name)")
        // At once, so it isn't shown again in a combo, attached, before the watch says it's gone.
        store.forget(surface: surface.id)
        // A Den that has already gone is not an error.
        if !keepDen, let den = store.den(of: surface) {
            _ = try await store.request("DELETE", "\(root)/dens/\(den.metadata.name)")
        }
        trees[surface.id] = nil
        pages[surface.id] = nil
    }

    /// Ghostty's goto_tab: a stop number from 1, or previous, next or last. A combo is one
    /// stop, and brings back the tab of it last in front. Returns false when there is no tab
    /// to go to.
    func gotoTab(_ tab: ghostty_action_goto_tab_e) -> Bool {
        let stops = self.stops
        guard !stops.isEmpty else { return false }
        let current = stops.firstIndex { $0.contains { $0.id == active } }
        let index: Int
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS: index = ((current ?? 0) + stops.count - 1) % stops.count
        case GHOSTTY_GOTO_TAB_NEXT: index = ((current ?? -1) + 1) % stops.count
        case GHOSTTY_GOTO_TAB_LAST: index = stops.count - 1
        default:
            guard tab.rawValue >= 1 else { return false }
            index = min(Int(tab.rawValue) - 1, stops.count - 1)
        }
        let last = selected.flatMap { recent[$0] }?.last { id in stops[index].contains { $0.id == id } }
        show(stops[index].first { $0.id == last } ?? stops[index][0])
        return true
    }

    /// Ghostty's move_tab: moves the tab in front, with its combo, left (negative) or right.
    func moveTab(by amount: Int) -> Bool {
        guard let active, let from = stops.firstIndex(where: { $0.contains { $0.id == active } }) else { return false }
        move(active, to: from + amount)
        return true
    }

    /// Moves a tab, with its combo, to a place among the stops in the tab bar, by writing the
    /// new `order` of the Space's Surfaces to dennet. A glued tab comes right after the tab
    /// it is glued to, so that it stays there when unglued.
    func move(_ id: String, to index: Int) {
        var stops = self.stops
        guard let from = stops.firstIndex(where: { $0.contains { $0.id == id } }) else { return }
        let to = min(max(index, 0), stops.count - 1)
        guard to != from else { return }
        stops.insert(stops.remove(at: from), at: to)
        writeOrder("surfaces", stops.joined().map { ($0.metadata, $0.spec.order) }, failure: "Could not move the tab")
    }

    /// Glues a tab beside another tab of its Space, on its right, by writing the first's
    /// `beside` to dennet: the two show side by side, as one combo tab. Then shows it. A tab
    /// already in a combo can't be glued, or glued onto: unglue it first.
    func glue(_ id: String, beside target: String) {
        let store = SpaceStore.shared
        guard id != target, let surface = store.surfaces[id], let main = store.surfaces[target],
              surface.metadata.namespace == main.metadata.namespace, surface.spec.space == main.spec.space,
              combo(of: surface).count == 1, combo(of: main).count == 1 else { return NSSound.beep() }
        Task { @MainActor in
            // A `beside` left on the tab glued onto, naming a tab that glues nothing, would
            // keep this from counting.
            if main.spec.beside != nil,
               await !self.patchSpec("surfaces", main.metadata, ["beside": NSNull()], failure: "Could not glue the tab") { return }
            guard await self.patchSpec("surfaces", surface.metadata, ["beside": main.metadata.name, "width": NSNull()],
                                       failure: "Could not glue the tab") else { return }
            if self.tabs.contains(where: { $0.id == id }) { self.show(surface) }
        }
    }

    /// The tab that Glue to Tab on the Left glues a tab beside: the one left of it, when
    /// neither is in a combo.
    func glueTarget(left id: String) -> Surface? {
        let stops = self.stops
        guard let at = stops.firstIndex(where: { $0.count == 1 && $0[0].id == id }), at > 0,
              stops[at - 1].count == 1 else { return nil }
        return stops[at - 1][0]
    }

    /// Unglues a combo, either of whose tabs is `id`: each becomes a tab of its own. `id`
    /// goes to stop `index` among the others, or else stays next to the other tab, on its
    /// own side.
    func unglue(_ id: String, to index: Int? = nil) {
        var stops = self.stops
        guard let at = stops.firstIndex(where: { $0.count == 2 && $0.contains { $0.id == id } }) else { return NSSound.beep() }
        let combo = stops[at]
        stops[at] = combo.filter { $0.id != id }
        stops.insert(combo.filter { $0.id == id }, at: index.map { min(max($0, 0), stops.count) } ?? (combo[0].id == id ? at : at + 1))
        Task { @MainActor in
            guard await self.patchSpec("surfaces", combo[1].metadata, ["beside": NSNull()],
                                       failure: "Could not unglue the tab") else { return }
            self.writeOrder("surfaces", stops.joined().map { ($0.metadata, $0.spec.order) }, failure: "Could not move the tab")
        }
    }

    /// Moves a Space to a place among its siblings (in sidebar order), by writing the new
    /// `order` of the siblings to dennet. Its parent stays the same.
    func moveSpace(_ id: String, among siblings: [Space], to index: Int) {
        var siblings = siblings
        guard let from = siblings.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), siblings.count - 1)
        guard to != from else { return }
        siblings.insert(siblings.remove(at: from), at: to)
        writeOrder("spaces", siblings.map { ($0.metadata, $0.spec.order) }, failure: "Could not move the Space")
    }

    /// Numbers objects 10, 20, 30... in the given order, patching only those whose `order`
    /// changes.
    private func writeOrder(_ resource: String, _ objects: [(ObjectMeta, Int32?)], failure: String) {
        Task { @MainActor in
            do {
                for (i, (meta, order)) in objects.enumerated() where order != Int32((i + 1) * 10) {
                    let path = "/apis/den.mkm.pub/v1alpha1/namespaces/\(meta.namespace ?? "default")/\(resource)/\(meta.name)"
                    _ = try await SpaceStore.shared.request(
                        "PATCH", path, json: ["spec": ["order": (i + 1) * 10]], contentType: "application/merge-patch+json")
                }
            } catch {
                self.alert(failure, error)
            }
        }
    }

    private struct Created: Decodable {
        var metadata: ObjectMeta
    }

    private func alert(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window = controller?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The rows and columns of a terminal already open in this window that fills the tab
    /// area, the one in front first. A new tab gets the same size.
    private func tabSize(_ controller: TerminalController) -> (rows: UInt16, columns: UInt16)? {
        for tree in [controller.surfaceTree] + Array(trees.values) {
            if case let .leaf(view) = tree.root, let size = view.surfaceSize { return (size.rows, size.columns) }
        }
        return nil
    }

    private func makeView(_ surface: Surface, controller: TerminalController) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = Self.attachCommand(
            namespace: surface.metadata.namespace ?? "default", den: surface.spec.terminal?.den ?? "",
            size: tabSize(controller))
        config.initialInput = pendingInput.removeValue(forKey: surface.id)
        guard let app = controller.ghostty.app else { preconditionFailure("app must be loaded") }
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        // Ghostty keeps a terminal given a command open after it exits, saying it exited,
        // until a key is pressed. den attach exiting means the den stopped or let go, so the
        // terminal closes at once and the tab shows why. A quick or failed exit (level
        // error) stays, so its error can be read. Ghostty reports an exit only while the
        // terminal is in a window; one exited out of sight is dropped when shown.
        exits[surface.id] = view.$childExitedMessage
            .compactMap { $0 }
            .filter { $0.level == .success }
            .first()
            .sink { [weak self, weak view] _ in
                guard let view else { return }
                self?.controller?.closeSurface(view, withConfirmation: false)
            }
        return view
    }

    static func denURL(_ namespace: String, _ den: String) -> String {
        "http://dennet/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)/dens/\(den)"
    }

    /// The command a terminal tab runs. A Den on a Host is attached on that Host: ssh
    /// runs den there, against the dennet there, where the Den is in "default".
    ///
    /// A new Ghostty surface starts at a fixed 800x600 pixels (about 50 columns) and gets its
    /// real size a moment later, after layout. If den attach started at once, den would
    /// shrink the session to 50 columns and rewrap everything on screen. So a small sh
    /// script waits for the first resize (SIGWINCH), or half a second, before starting den
    /// (or ssh). The resize can come before the script listens for it, so when `size` (that
    /// of another tab in the window) is given and the terminal already has it, the script
    /// does not wait. `env` keeps sh from becoming a login shell: Ghostty starts commands with
    /// `exec -l`.
    ///
    /// Reaching a Host can be slow, so until den draws, the tab says in grey what it is
    /// waiting for: ssh, then the shell there. The screen is cleared just before den runs.
    ///
    /// To see where the time goes, `defaults write pub.mkm.dense dense.debugAttach -bool
    /// true`: then each step's line starts with the time in milliseconds, ssh runs with -v,
    /// and the screen is not cleared, so it all stays in the tab's scrollback. den starts
    /// 5 seconds late, so the lines can be read before it draws over them.
    static func attachCommand(namespace: String, den: String, size: (rows: UInt16, columns: UInt16)? = nil) -> String {
        let sized = size.map { #"[ "$(stty size)" = "\#($0.rows) \#($0.columns)" ] || "# } ?? ""
        let waitForSize = #"trap : WINCH; \#(sized){ sleep 0.5 & wait $!; kill $! 2>/dev/null; }; exec "$0" "$@""#
        var command: [String]
        if let host = SpaceStore.shared.hosts.values.first(where: { $0.metadata.name == namespace }) {
            let debug = UserDefaults.standard.bool(forKey: "dense.debugAttach")
            let dest = host.spec.ssh
            command = ["/bin/sh", "-c", waitForSize,
                       "/bin/sh", "-c", say(debug ? "Connecting to %s, size %s…" : "Connecting to %s…", debug: debug) + (debug ? #" "$1" "$(stty size)""# : #" "$1""#) + #"; shift; exec "$@""#, "sh", dest,
                       "/usr/bin/ssh", "-t"] + (debug ? ["-v"] : []) + ["--", dest, remoteAttach(host.spec, den: den, debug: debug)]
            if debug {
                // The size (rows columns) before and after the wait shows whether it was needed.
                command = ["/bin/sh", "-c", say("Waiting for the terminal's size, now %s…", debug: true) + #" "$(stty size)"; exec "$0" "$@""#] + command
            }
        } else {
            command = ["/bin/sh", "-c", waitForSize,
                       denPath, "attach", "--unix-socket", SpaceStore.shared.socketPath, "-f", denURL(namespace, den)]
        }
        return (["/usr/bin/env"] + command).map(shellQuote).joined(separator: " ")
    }

    /// The command ssh runs on a Host to attach to one of its Dens. sshd hands it to the
    /// user's shell there, which may not be sh, so it is wrapped in sh -c. It finds the
    /// dennet socket where `dennet server run` puts it, unless the Host names one. It runs
    /// the Host's `denPath`, or else den from a login, interactive shell, which reads the
    /// files that put den on the PATH.
    static func remoteAttach(_ host: DennetHost.Spec, den: String, debug: Bool = false) -> String {
        let findSocket = host.socketPath.map { "s=\(shellQuote($0))" }
            ?? #"for s in ${XDG_RUNTIME_DIR:+"$XDG_RUNTIME_DIR/dennet/dennet.sock"} "${XDG_STATE_HOME:-$HOME/.local/state}/dennet/dennet.sock"; do [ -S "$s" ] && break; done"#
        let url = denURL("default", den)
        // Clears the screen and its scrollback; sh's printf makes the escape characters.
        let clear = debug ? "c=" : #"c=$(printf '\033[H\033[2J\033[3J')"#
        let attach = if let denPath = host.denPath {
            say("Starting den…", debug: debug) + (debug ? "; sleep 5" : "")
                + #"; printf %s "$c"; exec \#(shellQuote(denPath)) attach --unix-socket "$s" -f \#(url)"#
        } else {
            // Login and interactive, like a terminal's shell: zsh reads .zshrc, where PATH
            // is often set, only when interactive. Inside double quotes, so sh puts in the
            // socket path and the escape characters before that shell runs it.
            say("Starting a login shell to run den…", debug: debug)
                + #"; exec "${SHELL:-sh}" -l -i -c ""#
                // Through sh, as the shell there may be fish.
                + (debug ? doubleQuoted("sh -c " + shellQuote(say("Login shell ready, starting den in 5 s…", debug: true) + "; sleep 5")) + "; " : "")
                + #"printf %s '$c'; exec den attach --unix-socket '$s' -f \#(url)""#
        }
        return "sh -c " + shellQuote([findSocket, clear, attach].joined(separator: "; "))
    }

    /// A printf command that shows a line in grey. `format` may hold a %s. With `debug`, the
    /// line starts with the time, to the millisecond if perl is there.
    private static func say(_ format: String, debug: Bool = false) -> String {
        let time = #"{ perl -MTime::HiRes=time -MPOSIX=strftime -e '$t = time; printf "%s.%03d ", strftime("%H:%M:%S", localtime $t), 1000 * ($t - int $t)' 2>/dev/null || date '+%H:%M:%S '; }; "#
        return (debug ? #"printf '\033[2m'; "# + time : "") + "printf " + shellQuote(#"\033[2m"# + format + #"\033[0m\r\n"#)
    }

    /// Escapes sh code to go inside double quotes, so that the shell they are passed to
    /// sees it as written.
    private static func doubleQuoted(_ code: String) -> String {
        code.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// Quotes a word for sh.
    static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Where `den` is. Apps started from the Finder don't get the PATH a shell's rc files
    /// set up, so look in the usual places first.
    /// ponytail: fixed list; make it a setting when someone keeps den somewhere else.
    static let denPath: String = {
        let home = NSHomeDirectory()
        let dirs = ["\(home)/bin", "\(home)/.local/bin", "\(home)/go/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { "\($0)/den" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "den"
    }()
}

/// Completes a tag being typed in a token field from the tags in use.
private final class TagCompletions: NSObject, NSTokenFieldDelegate {
    private let tags: [String]

    init(_ tags: [String]) {
        self.tags = Array(Set(tags)).sorted()
    }

    func tokenField(
        _ tokenField: NSTokenField,
        completionsForSubstring substring: String,
        indexOfToken tokenIndex: Int,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
        let typed = substring.drop { $0 == "#" }
        return tags.filter { $0.lowercased().hasPrefix(typed.lowercased()) }
    }
}
