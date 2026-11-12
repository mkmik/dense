import AppKit
import SwiftUI

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
            CommandOption(title: "Open Space…", symbols: ["⌘", "O"], leadingIcon: "folder") {
                // Once this palette has closed and given the focus back to the terminal.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.sendAction(#selector(TerminalController.openSpace(_:)), to: nil, from: nil)
                }
            },
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
                CommandOption(title: "Archive Space", subtitle: name, leadingIcon: "archivebox") { self.archiveSpace(space) },
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
        options += store.spaces.values.filter { $0.spec.archived != true }.map { other in
            CommandOption(title: "Go to Space: \(Self.title(other))", subtitle: Self.path(other, in: store.spaces),
                          leadingIcon: "folder") { self.select(other) }
        }
        return options
    }

    /// Every Space, this machine's then each Host's, in the sidebar's order and drawn as there,
    /// for Open Space (⌘K). The palette searches each one's title, the titles above it, and
    /// its tags as "#tag". Collapsed Spaces show their subspaces here. The archived Spaces
    /// come last, greyed out and found by "archived" too; opening one brings it back. Each
    /// row shows its whole path, "space / subspace / subsubspace", rather than indenting.
    func openOptions(look: TerminalLook) -> [CommandOption] {
        let store = SpaceStore.shared
        let cell = look.cell
        return [false, true].flatMap { archived in
            let rows = ([nil] + store.hostNames.map(Optional.some)).flatMap { host in
                Space.rows(store.spaces(on: host, archived: archived).map { space in
                    var space = space
                    space.spec.collapsed = nil
                    return space
                })
            }
            return rows.map { row in
                let path = Self.path(row.space, in: store.spaces)
                let tags = row.space.spec.tags.map { $0.map { "#" + $0 }.joined(separator: " ") }
                return CommandOption(
                    title: Self.title(row.space),
                    subtitle: path,
                    description: archived ? ["archived", tags].compactMap { $0 }.joined(separator: " ") : tags,
                    row: AnyView(SpaceRow(space: row.space, look: look, cell: cell,
                                          title: [path, Self.title(row.space)].compactMap { $0 }.joined(separator: " / "))
                        .opacity(archived ? 0.5 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(Font(look.font)))
                ) { archived ? self.unarchiveSpace(row.space) : self.select(row.space) }
            }
        }
    }

    private static func title(_ space: Space) -> String {
        space.spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.metadata.name
    }

    /// The titles of the Spaces above, as "a / b", or nil at the top.
    private static func path(_ space: Space, in spaces: [String: Space]) -> String? {
        var titles: [String] = []
        var seen: Set<String> = [space.id]
        var parent = space.spec.parent
        while let name = parent, let up = spaces[objectID(space.metadata.namespace, name)], seen.insert(up.id).inserted {
            titles.insert(title(up), at: 0)
            parent = up.spec.parent
        }
        return titles.isEmpty ? nil : titles.joined(separator: " / ")
    }
}
