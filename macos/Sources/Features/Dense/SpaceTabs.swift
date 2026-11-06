import AppKit
import Combine
import Foundation

/// Shows the terminal Surfaces of the selected Space as the native tabs of a window.
///
/// Each Surface gets its own TerminalController, whose window is one native tab, running
/// `den attach`. Selecting a Space moves its windows into the window's tab group in
/// `order`, then takes the other Spaces' windows out of the group and hides them. Hidden
/// windows keep running, so switching back is instant and nothing is attached twice.
/// Plain Ghostty tabs, which are not Surfaces, are left where they are.
final class SpaceTabs: ObservableObject {
    static let shared = SpaceTabs()

    /// The id of the selected Space.
    @Published private(set) var selected: String?

    /// One controller per Surface id, made the first time its Space is selected.
    private var controllers: [String: TerminalController] = [:]

    /// The Surface id of the tab that was in front when each Space (by id) was left.
    private var lastTab: [String: String] = [:]

    func select(_ space: Space, in window: NSWindow) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }

        // ponytail: a Space with no terminal Surfaces can't be shown yet; making a tab in it
        // comes with writing back to dennet.
        let surfaces = space.terminals(Array(SpaceStore.shared.surfaces.values))
        guard !surfaces.isEmpty else { return }
        let tabs = surfaces.compactMap { controller(for: $0, ghostty: ghostty, like: window).window }

        if let selected, let front = window.tabGroup?.selectedWindow {
            lastTab[selected] = surfaceID(of: front)
        }

        // Put the tabs in order around `window`, which stays in place while they move.
        let anchor = tabs.firstIndex(of: window)
        for tab in tabs.prefix(anchor ?? 0) { move(tab, next: window, .below) }
        for tab in tabs.suffix(from: (anchor ?? -1) + 1).reversed() { move(tab, next: window, .above) }

        let front = tabs.first { surfaceID(of: $0) == lastTab[space.id] } ?? tabs[0]
        guard let group = front.tabGroup else { return }
        group.selectedWindow = front
        front.makeKeyAndOrderFront(nil)

        // Hide the other Spaces' tabs. `window` itself may be one of them.
        let surfaceWindows = controllers.values.compactMap(\.window)
        for other in group.windows where surfaceWindows.contains(other) && !tabs.contains(other) {
            group.removeWindow(other)
            other.orderOut(nil)
        }

        selected = space.id
        (front.windowController as? TerminalController)?.relabelTabs()
    }

    private func move(_ tab: NSWindow, next anchor: NSWindow, _ order: NSWindow.OrderingMode) {
        if tab.tabGroup === anchor.tabGroup { anchor.tabGroup?.removeWindow(tab) }
        anchor.addTabbedWindowSafely(tab, ordered: order)
    }

    private func surfaceID(of window: NSWindow) -> String? {
        controllers.first { $0.value.window === window }?.key
    }

    private func controller(for surface: Surface, ghostty: Ghostty.App, like window: NSWindow) -> TerminalController {
        if let controller = controllers[surface.id] { return controller }

        var config = Ghostty.SurfaceConfiguration()
        config.command = Self.attachCommand(namespace: surface.metadata.namespace ?? "default", den: surface.spec.terminal?.den ?? "")
        let controller = TerminalController(ghostty, withBaseConfig: config)
        controller.isBackgroundOpaque = (window.windowController as? BaseTerminalController)?.isBackgroundOpaque ?? false
        controller.titleOverride = surface.spec.title.flatMap { $0.isEmpty ? nil : $0 }
        controllers[surface.id] = controller

        // When the tab closes (den attach exited, or the user closed it), forget it so the
        // next selection attaches again.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) { [weak self] _ in
            self?.controllers[surface.id] = nil
        }
        return controller
    }

    static func attachCommand(namespace: String, den: String) -> String {
        let url = "http://dennet/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)/dens/\(den)"
        return "'\(denPath)' attach --unix-socket '\(SpaceStore.shared.socketPath)' -f '\(url)'"
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
