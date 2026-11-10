import AppKit

/// dense's items in the View menu.
enum SidebarMenu {
    /// The user default behind View > Show Tree Lines, which the sidebar reads.
    static let treeLinesKey = "dense.sidebarTreeLines"

    /// Whether the sidebar draws tree lines.
    static var treeLines: Bool {
        get { UserDefaults.standard.bool(forKey: treeLinesKey) }
        set { UserDefaults.standard.set(newValue, forKey: treeLinesKey) }
    }

    /// Adds the items at the end of the View menu.
    static func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Show Tree Lines", action: #selector(Target.toggleTreeLines(_:)), keyEquivalent: "")
        item.target = Target.shared
        view.addItem(.separator())
        view.addItem(item)
    }

    /// Menu items hold their target weakly, so it is a long-lived object.
    /// The command palette can toggle it too, so the check mark is set each time the menu opens.
    private final class Target: NSObject, NSMenuItemValidation {
        static let shared = Target()

        @objc func toggleTreeLines(_ item: NSMenuItem) { SidebarMenu.treeLines.toggle() }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            item.state = SidebarMenu.treeLines ? .on : .off
            return true
        }
    }
}
