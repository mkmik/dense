import AppKit

/// dense's items in the View menu.
enum SidebarMenu {
    /// The user default behind View > Show Tree Lines, which the sidebar reads.
    static let treeLinesKey = "dense.sidebarTreeLines"

    /// Adds the items at the end of the View menu.
    static func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Show Tree Lines", action: #selector(Target.toggleTreeLines(_:)), keyEquivalent: "")
        item.target = Target.shared
        item.state = UserDefaults.standard.bool(forKey: treeLinesKey) ? .on : .off
        view.addItem(.separator())
        view.addItem(item)
    }

    /// Menu items hold their target weakly, so it is a long-lived object.
    private final class Target: NSObject {
        static let shared = Target()

        @objc func toggleTreeLines(_ item: NSMenuItem) {
            let on = !UserDefaults.standard.bool(forKey: SidebarMenu.treeLinesKey)
            UserDefaults.standard.set(on, forKey: SidebarMenu.treeLinesKey)
            item.state = on ? .on : .off
        }
    }
}
