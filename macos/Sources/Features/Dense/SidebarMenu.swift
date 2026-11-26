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

    /// The user default behind View > Show Sections, which the sidebar reads. It is set
    /// when sections are off, so they are on by default.
    static let noSectionsKey = "dense.sidebarNoSections"

    /// Whether the sidebar draws top-level Spaces as sections.
    static var sections: Bool {
        get { !UserDefaults.standard.bool(forKey: noSectionsKey) }
        set { UserDefaults.standard.set(!newValue, forKey: noSectionsKey) }
    }

    /// Adds the items at the end of the View menu.
    static func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Show Tree Lines", action: #selector(Target.toggleTreeLines(_:)), keyEquivalent: "")
        item.target = Target.shared
        view.addItem(.separator())
        view.addItem(item)
        let sections = NSMenuItem(title: "Show Sections", action: #selector(Target.toggleSections(_:)), keyEquivalent: "")
        sections.target = Target.shared
        view.addItem(sections)
        // To the window's controller, through the responder chain.
        view.addItem(NSMenuItem(title: "Open Space…", action: #selector(TerminalController.openSpace(_:)), keyEquivalent: "k"))
    }

    /// Menu items hold their target weakly, so it is a long-lived object.
    /// The command palette can toggle it too, so the check mark is set each time the menu opens.
    private final class Target: NSObject, NSMenuItemValidation {
        static let shared = Target()

        @objc func toggleTreeLines(_ item: NSMenuItem) { SidebarMenu.treeLines.toggle() }
        @objc func toggleSections(_ item: NSMenuItem) { SidebarMenu.sections.toggle() }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            let on = item.action == #selector(toggleSections(_:)) ? SidebarMenu.sections : SidebarMenu.treeLines
            item.state = on ? .on : .off
            return true
        }
    }
}
