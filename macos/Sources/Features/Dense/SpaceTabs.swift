import Combine
import Foundation

/// The Space shown in one window, and which of its tabs (Surfaces) is in front.
///
/// The window's terminal area shows one tab at a time by swapping the controller's
/// surface tree. Each terminal Surface gets its own Ghostty surface running `den attach`,
/// made the first time the tab is shown. Tabs out of view keep running, so switching is
/// instant and nothing attaches twice. The terminal the window opened with is closed as
/// soon as a tab is shown.
///
/// The selected Space and each Space's front tab are saved in the user defaults, and a new
/// window opens on them once dennet's lists have loaded.
final class SpaceTabs: ObservableObject {
    /// The id of the Space shown, or nil while the window shows its own terminal.
    @Published private(set) var selected: String?

    /// The Surface id of the tab in front, or nil when the Space shows no tab.
    @Published private(set) var active: String?

    private weak var controller: TerminalController?

    /// Each tab's terminal tree, by Surface id. A tree can hold splits made inside the tab.
    private var trees: [String: SplitTree<Ghostty.SurfaceView>] = [:]

    /// The tab last in front in each Space, by Space id.
    private var lastTab: [String: String]

    private var restore: AnyCancellable?

    private static let selectedKey = "dense.selectedSpace"
    private static let lastTabKey = "dense.lastTab"

    init(controller: TerminalController) {
        self.controller = controller
        let defaults = UserDefaults.standard
        lastTab = defaults.dictionary(forKey: Self.lastTabKey) as? [String: String] ?? [:]

        // Show the saved Space right away (no terminal yet, so the window's own terminal
        // doesn't flash), and its tab once dennet's lists are in.
        selected = defaults.string(forKey: Self.selectedKey)
        restore = SpaceStore.shared.$loaded.first { $0 }.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let id = self.selected else { return }
            if let space = SpaceStore.shared.spaces[id] { self.select(space) } else { self.selected = nil }
        }
    }

    func select(_ space: Space) {
        selected = space.id
        let surfaces = space.terminals(Array(SpaceStore.shared.surfaces.values))
        show(surfaces.first { $0.id == lastTab[space.id] } ?? surfaces.first)
    }

    /// Brings a tab of the selected Space to the front; nil shows no tab.
    func show(_ surface: Surface?) {
        guard let controller else { return }

        // Set aside the tab in front. If no tab is, the window shows its own terminal or
        // nothing, and that is dropped.
        if let active { trees[active] = controller.surfaceTree }

        active = surface?.id
        if let selected, let surface { lastTab[selected] = surface.id }
        UserDefaults.standard.set(selected, forKey: Self.selectedKey)
        UserDefaults.standard.set(lastTab, forKey: Self.lastTabKey)

        guard let surface else {
            controller.surfaceTree = .init()
            return
        }

        // A tab whose den attach has exited is attached again.
        let tree = trees[surface.id].flatMap { $0.allSatisfy(\.processExited) ? nil : $0 }
            ?? SplitTree(view: makeView(surface, controller: controller))
        let old = controller.focusedSurface
        controller.surfaceTree = tree
        if let view = tree.root?.leftmostLeaf() {
            DispatchQueue.main.async { Ghostty.moveFocus(to: view, from: old) }
        }
    }

    /// Called when the terminal filling the window is closing (den attach exited, or the
    /// user closed it). If it is a tab, the tab is dropped and the next one is shown, and
    /// this returns true. Otherwise it returns false and the window closes as usual.
    func closeActiveTab() -> Bool {
        guard let closing = active else { return false }
        trees[closing] = nil
        active = nil

        // ponytail: the Surface is still in dennet, so its tab stays in the tab bar and a
        // click attaches again. Deleting the Surface comes with writing back to dennet.
        let space = selected.flatMap { SpaceStore.shared.spaces[$0] }
        show(space?.terminals(Array(SpaceStore.shared.surfaces.values)).first { $0.id != closing })
        return true
    }

    private func makeView(_ surface: Surface, controller: TerminalController) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = Self.attachCommand(namespace: surface.metadata.namespace ?? "default", den: surface.spec.terminal?.den ?? "")
        guard let app = controller.ghostty.app else { preconditionFailure("app must be loaded") }
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    /// The command a terminal tab runs.
    ///
    /// A new Ghostty surface starts at a fixed 800x600 pixels (about 50 columns) and gets its
    /// real size a moment later, after layout. If den attach started at once, den would
    /// shrink the session to 50 columns and rewrap everything on screen. So a small sh
    /// script waits for the first resize (SIGWINCH), or half a second, before starting den.
    /// `env` keeps sh from becoming a login shell: Ghostty starts commands with `exec -l`.
    static func attachCommand(namespace: String, den: String) -> String {
        let url = "http://dennet/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)/dens/\(den)"
        let waitForSize = #"trap : WINCH; sleep 0.5 & wait $!; kill $! 2>/dev/null; exec "$0" "$@""#
        return "/usr/bin/env /bin/sh -c '\(waitForSize)' '\(denPath)' attach --unix-socket '\(SpaceStore.shared.socketPath)' -f '\(url)'"
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
