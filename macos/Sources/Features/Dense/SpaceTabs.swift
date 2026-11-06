import AppKit
import Combine
import Foundation
import GhosttyKit

/// The Space shown in one window, and which of its tabs (Surfaces) is in front.
///
/// The window's terminal area shows one tab at a time by swapping the controller's
/// surface tree. Each terminal Surface gets its own Ghostty surface running `den attach`,
/// made the first time the tab is shown. Tabs out of view keep running, so switching is
/// instant and nothing attaches twice. The terminal the window opened with is closed as
/// soon as a tab is shown.
///
/// dense has no macOS window tabs. Ghostty's tab commands (new tab, go to tab, move tab,
/// close tab), from key bindings, menus, AppleScript, Shortcuts or Services, act on these
/// tabs instead. A new tab is a new Den and Surface in dennet.
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

    /// Text to type into a new tab once it is attached, by Surface id.
    private var pendingInput: [String: String] = [:]

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

    /// The selected Space's terminal tabs, in order.
    var tabs: [Surface] {
        guard let selected, let space = SpaceStore.shared.spaces[selected] else { return [] }
        return space.terminals(Array(SpaceStore.shared.surfaces.values))
    }

    /// The terminal of a tab that has been shown, for its live title.
    func terminal(for surface: Surface) -> Ghostty.SurfaceView? {
        let tree = surface.id == active ? controller?.surfaceTree : trees[surface.id]
        return tree?.root?.leftmostLeaf()
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
        show(tabs.first { $0.id != closing })
        return true
    }

    /// Makes a new tab at the end of the selected Space: a Den and a Surface in dennet, then
    /// shows it. `config` is what Ghostty asks of a new tab: working directory, command,
    /// environment, or text to type.
    func newTab(_ config: Ghostty.SurfaceConfiguration?) {
        guard let selected, let space = SpaceStore.shared.spaces[selected] else {
            NSSound.beep()
            return
        }
        let namespace = space.metadata.namespace ?? "default"
        let order = (tabs.compactMap(\.spec.order).max() ?? 0) + 10

        var den: [String: Any] = [
            "workingDir": config?.workingDirectory ?? controller?.focusedSurface?.pwd ?? NSHomeDirectory(),
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

                // ponytail: dennet does not start dens yet, so dense runs den apply. If the
                // Surface below fails, the Den keeps running without a tab.
                try await Self.run(Self.denPath, ["apply", "--unix-socket", store.socketPath, "-f", Self.denURL(namespace, name)])

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

    /// Ghostty's move_tab: moves the tab in front left (negative) or right, by writing the
    /// new `order` of the Space's Surfaces to dennet.
    func moveTab(by amount: Int) -> Bool {
        var tabs = self.tabs
        guard let from = tabs.firstIndex(where: { $0.id == active }) else { return false }
        let to = min(max(from + amount, 0), tabs.count - 1)
        guard to != from else { return true }
        tabs.insert(tabs.remove(at: from), at: to)

        Task { @MainActor in
            do {
                for (i, surface) in tabs.enumerated() where surface.spec.order != Int32((i + 1) * 10) {
                    let path = "/apis/den.mkm.pub/v1alpha1/namespaces/\(surface.metadata.namespace ?? "default")/surfaces/\(surface.metadata.name)"
                    _ = try await SpaceStore.shared.request(
                        "PATCH", path, json: ["spec": ["order": (i + 1) * 10]], contentType: "application/merge-patch+json")
                }
            } catch {
                self.alert("Could not move the tab", error)
            }
        }
        return true
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

    /// Runs a program and waits for it. A failure throws with what it wrote to stderr.
    ///
    /// stderr goes to a temporary file, not a pipe: den apply leaves a process running in
    /// the background, and that process must not be left writing into a closed pipe.
    private static func run(_ path: String, _ arguments: [String]) async throws {
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("dense-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errorFile)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let message = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: errorFile)
                guard process.terminationStatus != 0 else { return continuation.resume() }
                continuation.resume(throwing: SpaceStore.RequestError(message: "\(path) failed: \(message)"))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func makeView(_ surface: Surface, controller: TerminalController) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = Self.attachCommand(namespace: surface.metadata.namespace ?? "default", den: surface.spec.terminal?.den ?? "")
        config.initialInput = pendingInput.removeValue(forKey: surface.id)
        guard let app = controller.ghostty.app else { preconditionFailure("app must be loaded") }
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    static func denURL(_ namespace: String, _ den: String) -> String {
        "http://dennet/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)/dens/\(den)"
    }

    /// The command a terminal tab runs.
    ///
    /// A new Ghostty surface starts at a fixed 800x600 pixels (about 50 columns) and gets its
    /// real size a moment later, after layout. If den attach started at once, den would
    /// shrink the session to 50 columns and rewrap everything on screen. So a small sh
    /// script waits for the first resize (SIGWINCH), or half a second, before starting den.
    /// `env` keeps sh from becoming a login shell: Ghostty starts commands with `exec -l`.
    static func attachCommand(namespace: String, den: String) -> String {
        let waitForSize = #"trap : WINCH; sleep 0.5 & wait $!; kill $! 2>/dev/null; exec "$0" "$@""#
        return "/usr/bin/env /bin/sh -c '\(waitForSize)' '\(denPath)' attach --unix-socket '\(SpaceStore.shared.socketPath)' -f '\(denURL(namespace, den))'"
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
