import AppKit

/// dense's commands in the command palette: what the Space and tab menus do, the View menu's
/// tree lines, and a "Go to Space" for every Space. Ghostty's own New Tab and Close Tab
/// already act on the Space's tabs.
extension SpaceTabs {
    /// Asks the sidebar of this window to open its filter field and focus it.
    static let focusFilter = Notification.Name("dense.focusFilter")

    var paletteOptions: [CommandOption] {
        let store = SpaceStore.shared
        let space = selected.flatMap { store.spaces[$0] }
        let tab = active.flatMap { store.surfaces[$0] }
        var options: [CommandOption] = [
            CommandOption(title: "New Space", leadingIcon: "plus.rectangle.on.folder") { self.newSpace(parent: nil) },
            CommandOption(title: "Filter Spaces", description: "Filter the sidebar by title, or #tag",
                          leadingIcon: "line.3.horizontal.decrease.circle") {
                NotificationCenter.default.post(name: Self.focusFilter, object: self)
            },
            CommandOption(title: SidebarMenu.treeLines ? "Hide Tree Lines" : "Show Tree Lines",
                          leadingIcon: "list.bullet.indent") { SidebarMenu.treeLines.toggle() },
        ]
        if let space {
            let name = Self.title(space)
            options += [
                CommandOption(title: "New Subspace", subtitle: name, leadingIcon: "folder.badge.plus") { self.newSpace(parent: space) },
                CommandOption(title: "Rename Space", subtitle: name, leadingIcon: "pencil") { self.renameSpace(space) },
                CommandOption(title: "Edit Space Tags", subtitle: name, leadingIcon: "tag") { self.editTags(space) },
                CommandOption(title: "Delete Space", subtitle: name, leadingIcon: "trash") { self.deleteSpace(space) },
            ]
        }
        if let tab {
            options.append(CommandOption(title: "Rename Tab", subtitle: tab.spec.title, leadingIcon: "pencil") { self.renameTab(tab) })
            if store.den(of: tab)?.running == false {
                options.append(CommandOption(title: "Restart Den", leadingIcon: "arrow.clockwise") { self.restartDen(tab) })
            }
        }
        if NewBuild.shared.available {
            options.append(CommandOption(title: "Restart to Use New Build", leadingIcon: "power.circle", emphasis: true) { NewBuild.restart() })
        }
        options += store.spaces.values.map { other in
            CommandOption(title: "Go to Space: \(Self.title(other))", subtitle: Self.path(other, in: store.spaces),
                          leadingIcon: "folder") { self.select(other) }
        }
        return options
    }

    private static func title(_ space: Space) -> String {
        space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name
    }

    /// The titles of the Spaces above, as "a › b", or nil at the top.
    private static func path(_ space: Space, in spaces: [String: Space]) -> String? {
        var titles: [String] = []
        var seen: Set<String> = [space.id]
        var parent = space.spec.parent
        while let name = parent, let up = spaces[objectID(space.metadata.namespace, name)], seen.insert(up.id).inserted {
            titles.insert(title(up), at: 0)
            parent = up.spec.parent
        }
        return titles.isEmpty ? nil : titles.joined(separator: " › ")
    }
}
