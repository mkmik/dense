import AppKit
import Combine
import Foundation
import GhosttyKit

/// The Space shown in one window, and which of its tabs (Surfaces) is in front.
///
/// The window's terminal area shows one tab at a time by swapping the controller's
/// surface tree. Each terminal Surface gets its own Ghostty surface running `den attach`,
/// made the first time the tab is shown while its Den's status says it runs. Until then
/// the tab waits, and attaches as soon as the status changes. Tabs out of view keep
/// running, so switching is instant and nothing attaches twice. The terminal the window
/// opened with is closed as soon as a tab is shown.
///
/// dense has no macOS window tabs. Ghostty's tab commands (new tab, go to tab, move tab,
/// close tab), from key bindings, menus, AppleScript, Shortcuts or Services, act on these
/// tabs instead. A new tab is a new Den and Surface in dennet; dense does not start the
/// den, whoever runs Dens does.
///
/// The selected Space and each Space's front tab are saved in the user defaults, and a new
/// window opens on them once dennet's lists have loaded.
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

    /// Each tab's terminal tree, by Surface id. A tree can hold splits made inside the tab.
    private var trees: [String: SplitTree<Ghostty.SurfaceView>] = [:]

    /// The tab last in front in each Space, by Space id.
    private var lastTab: [String: String]

    /// The tabs shown in each Space, by Space id, most recent last, so closing tabs one
    /// after another goes back through them in turn.
    private var recent: [String: [String]] = [:]

    /// Text to type into a new tab once it is attached, by Surface id.
    private var pendingInput: [String: String] = [:]

    private var restore: AnyCancellable?
    private var denChanges: AnyCancellable?

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
            if let space = store.spaces[saved], store.loaded(space) {
                self.restore = nil
                self.select(space)
            } else if self.active == nil, self.controller?.surfaceTree.isEmpty == false {
                self.show(nil)
            }
        }

        // A waiting tab attaches as soon as its den runs.
        denChanges = SpaceStore.shared.$dens.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.waiting, let surface = self.tabs.first(where: { $0.id == self.active }),
                  SpaceStore.shared.den(of: surface)?.running == true else { return }
            self.show(surface)
        }
    }

    /// The selected Space's terminal tabs, in order.
    var tabs: [Surface] {
        guard let selected, let space = SpaceStore.shared.spaces[selected] else { return [] }
        return space.terminals(Array(SpaceStore.shared.surfaces.values))
    }

    func select(_ space: Space) {
        selected = space.id
        show(tabs.first { $0.id == lastTab[space.id] } ?? tabs.first)
    }

    /// Brings a tab of the selected Space to the front; nil shows no tab.
    func show(_ surface: Surface?) {
        guard let controller else { return }

        // Set aside the tab in front. If no tab is, the window shows its own terminal or
        // nothing, and that is dropped.
        if let active { trees[active] = controller.surfaceTree }

        active = surface?.id
        if let selected, let surface {
            lastTab[selected] = surface.id
            recent[selected, default: []].removeAll { $0 == surface.id }
            recent[selected, default: []].append(surface.id)
        }
        UserDefaults.standard.set(selected, forKey: Self.selectedKey)
        UserDefaults.standard.set(lastTab, forKey: Self.lastTabKey)

        // A tab whose den attach has exited is attached again, if its den runs.
        var tree: SplitTree<Ghostty.SurfaceView>?
        if let surface {
            tree = trees[surface.id].flatMap { $0.allSatisfy(\.processExited) ? nil : $0 }
            if tree == nil, SpaceStore.shared.den(of: surface)?.running == true {
                tree = SplitTree(view: makeView(surface, controller: controller))
            }
        }
        waiting = surface != nil && tree == nil
        guard let tree else {
            controller.surfaceTree = .init()
            return
        }
        let old = controller.focusedSurface
        controller.surfaceTree = tree
        if let view = tree.root?.leftmostLeaf() {
            DispatchQueue.main.async { Ghostty.moveFocus(to: view, from: old) }
            if let surface = view.surface, let raw = ghostty_surface_quicklook_font(surface) {
                // A copy of the CTFont, which is ours to release.
                let ctFont = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
                if font != ctFont as NSFont { font = ctFont as NSFont }
            }
        }
    }

    /// Called when the tab in front is to close: the user closed it (⌘W, File > Close Tab),
    /// or its den attach exited. If there is a tab in front this returns true, and
    /// otherwise false, so the window closes as usual.
    ///
    /// With `ask`, the user closed it: it asks, as the tab's menu does, whether to close it
    /// or detach from it. Without, den attach exited on its own (the den stopped, or the
    /// connection to it broke), so only the terminal goes: the tab stays, shows why its den
    /// isn't running, or attaches again when clicked.
    func closeActiveTab(ask: Bool) -> Bool {
        guard let closing = active else { return false }
        if ask {
            if let surface = SpaceStore.shared.surfaces[closing] { closeTab(surface) }
            return true
        }
        let next = tab(after: closing)
        trees[closing] = nil
        active = nil
        show(next)
        return true
    }

    /// The tab to show once `closing` goes: the one shown before it that is still there;
    /// else the one left of it, else the first. It is forgotten as shown.
    private func tab(after closing: String) -> Surface? {
        let rest = tabs.filter { $0.id != closing }
        guard let selected else { return rest.first }
        recent[selected]?.removeAll { $0 == closing }
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
        _ message: String, _ current: String?, placeholder: String = "Title", then done: @escaping (String) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = placeholder
        let alert = NSAlert()
        alert.messageText = message
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
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
        let path = "/apis/den.mkm.pub/v1alpha1/namespaces/\(meta.namespace ?? "default")/\(resource)/\(meta.name)"
        Task { @MainActor in
            do {
                _ = try await SpaceStore.shared.request(
                    "PATCH", path, json: ["spec": ["title": title as Any? ?? NSNull()]],
                    contentType: "application/merge-patch+json")
            } catch {
                self.alert(failure, error)
            }
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

    /// Asks, in a sheet like Ghostty's close confirmations, then deletes a Space from
    /// dennet with its subspaces, their tabs (Surfaces) and the Dens those attach to, which
    /// ends their terminal sessions. dennet does not delete dependent objects itself.
    func deleteSpace(_ space: Space) {
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
        let surfaces = doomed.flatMap { $0.terminals(Array(store.surfaces.values)) }
        let ids = seen

        let alert = NSAlert()
        alert.messageText = "Delete \"\(space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name)\"?"
        var gone: [String] = []
        if doomed.count > 1 { gone.append(doomed.count == 2 ? "1 subspace" : "\(doomed.count - 1) subspaces") }
        if !surfaces.isEmpty { gone.append(surfaces.count == 1 ? "1 tab" : "\(surfaces.count) tabs") }
        alert.informativeText = gone.isEmpty
            ? "This cannot be undone."
            : "Its \(gone.joined(separator: " and ")) will be deleted too, and their terminal sessions will be terminated."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let delete = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertFirstButtonReturn else { return }
            // As in Ghostty: keeps focus right when Stage Manager is used (#8336).
            alert.window.orderOut(nil)

            Task { @MainActor in
                let root = "/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)"
                do {
                    for surface in surfaces { try await self.delete(surface) }
                    // Children first, so no subspace shows at the top level for a moment.
                    for space in doomed.reversed() {
                        _ = try await store.request("DELETE", "\(root)/spaces/\(space.metadata.name)")
                    }
                } catch {
                    self.alert("Could not delete the Space", error)
                    return
                }
                // Move off the Space, dropping its tab in front. dennet's watch may not
                // have reported the deletes yet.
                guard let selected = self.selected, ids.contains(selected) else { return }
                self.active = nil
                if let next = Space.rows(store.spaces.values.filter { !ids.contains($0.id) }).first {
                    self.select(next.space)
                } else {
                    self.selected = nil
                    self.show(nil)
                }
            }
        }
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: delete)
        } else {
            delete(alert.runModal())
        }
    }

    /// Asks whether to close the tab, deleting its Surface and Den in dennet, which ends its
    /// den; or to detach, deleting only the Surface, so the den runs on without a tab. If
    /// it was in front, the next tab is shown.
    func closeTab(_ surface: Surface) {
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
            let keepDen = response == .alertSecondButtonReturn
            alert.window.orderOut(nil)
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
        if let window = controller?.window {
            alert.beginSheetModal(for: window, completionHandler: close)
        } else {
            close(alert.runModal())
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
    /// terminal.
    @MainActor
    private func delete(_ surface: Surface, keepDen: Bool = false) async throws {
        let store = SpaceStore.shared
        let root = "/apis/den.mkm.pub/v1alpha1/namespaces/\(surface.metadata.namespace ?? "default")"
        _ = try await store.request("DELETE", "\(root)/surfaces/\(surface.metadata.name)")
        // A Den that has already gone is not an error.
        if !keepDen, let den = store.den(of: surface) {
            _ = try await store.request("DELETE", "\(root)/dens/\(den.metadata.name)")
        }
        trees[surface.id] = nil
    }

    /// Ghostty's goto_tab: a tab number from 1, or previous, next or last. Returns false
    /// when there is no tab to go to.
    func gotoTab(_ tab: ghostty_action_goto_tab_e) -> Bool {
        let tabs = self.tabs
        guard !tabs.isEmpty else { return false }
        let current = tabs.firstIndex { $0.id == active }
        let index: Int
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS: index = ((current ?? 0) + tabs.count - 1) % tabs.count
        case GHOSTTY_GOTO_TAB_NEXT: index = ((current ?? -1) + 1) % tabs.count
        case GHOSTTY_GOTO_TAB_LAST: index = tabs.count - 1
        default:
            guard tab.rawValue >= 1 else { return false }
            index = min(Int(tab.rawValue) - 1, tabs.count - 1)
        }
        show(tabs[index])
        return true
    }

    /// Ghostty's move_tab: moves the tab in front left (negative) or right.
    func moveTab(by amount: Int) -> Bool {
        guard let active, let from = tabs.firstIndex(where: { $0.id == active }) else { return false }
        move(active, to: from + amount)
        return true
    }

    /// Moves a tab to a place in the tab bar, by writing the new `order` of the Space's
    /// Surfaces to dennet.
    func move(_ id: String, to index: Int) {
        var tabs = self.tabs
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), tabs.count - 1)
        guard to != from else { return }
        tabs.insert(tabs.remove(at: from), at: to)

        writeOrder("surfaces", tabs.map { ($0.metadata, $0.spec.order) }, failure: "Could not move the tab")
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
        return Ghostty.SurfaceView(app, baseConfig: config)
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
