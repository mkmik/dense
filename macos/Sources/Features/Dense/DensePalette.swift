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
            CommandOption(title: "New Space…", description: "Pick the Space it goes under",
                          leadingIcon: "plus.rectangle.on.folder") {
                // Once this palette has closed and given the focus back to the terminal.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.pickParent() }
            },
            CommandOption(title: "Filter Spaces", description: "Filter the sidebar by title, or #tag",
                          leadingIcon: "line.3.horizontal.decrease.circle") {
                NotificationCenter.default.post(name: Self.focusFilter, object: self)
            },
            CommandOption(title: SidebarMenu.treeLines ? "Hide Tree Lines" : "Show Tree Lines",
                          leadingIcon: "list.bullet.indent") { SidebarMenu.treeLines.toggle() },
            CommandOption(title: SidebarMenu.sections ? "Hide Sections" : "Show Sections",
                          leadingIcon: "rectangle.split.1x2") { SidebarMenu.sections.toggle() },
        ]
        if let space {
            let name = Self.title(space)
            options += [
                CommandOption(title: "New Browser Tab…", subtitle: name, description: "A tab that browses the web",
                              leadingIcon: "globe") { self.newWebTab(navigation: true) },
                CommandOption(title: "New Web Page Tab…", subtitle: name, description: "A tab that shows one page; links open in the browser",
                              leadingIcon: "doc.richtext") { self.newWebTab(navigation: false) },
                CommandOption(title: "New Subspace", subtitle: name, leadingIcon: "folder.badge.plus") { self.newSpace(parent: space) },
                CommandOption(title: "Rename Space", subtitle: name, leadingIcon: "pencil") { self.renameSpace(space) },
                CommandOption(title: "Edit Space Tags", subtitle: name, leadingIcon: "tag") { self.editTags(space) },
                CommandOption(title: "Archive Space", subtitle: name, leadingIcon: "archivebox") { self.archiveSpace(space) },
                CommandOption(title: "Delete Space", subtitle: name, leadingIcon: "trash") { self.deleteSpace(space) },
            ]
        }
        if let tab {
            options.append(CommandOption(title: "Rename Tab", subtitle: tab.spec.title, leadingIcon: "pencil") { self.renameTab(tab) })
            if stops.count > 1 {
                options.append(CommandOption(title: "Swap Tabs", description: "Swap this tab with the one on its left, like Emacs's C-t; the first tab swaps with the second",
                                             leadingIcon: "arrow.left.arrow.right") { self.swapTabs() })
            }
            if combo(of: tab).count > 1 {
                options.append(CommandOption(title: "Unglue Tab", description: "Show the two tabs of this combo as tabs of their own",
                                             leadingIcon: "rectangle") { self.unglue(tab.id) })
            } else {
                options += [
                    CommandOption(title: "New Browser Beside Tab…", subtitle: tab.spec.title,
                                  description: "A browser glued on the right of this tab, as one combo tab",
                                  leadingIcon: "globe") { self.newWebTab(navigation: true, beside: tab) },
                    CommandOption(title: "New Web Page Beside Tab…", subtitle: tab.spec.title,
                                  description: "One page glued on the right of this tab, as one combo tab",
                                  leadingIcon: "doc.richtext") { self.newWebTab(navigation: false, beside: tab) },
                ]
                if let left = glueTarget(left: tab.id) {
                    options.append(CommandOption(title: "Glue to Tab on the Left", subtitle: left.spec.title,
                                                 description: "Show this tab beside the tab on its left, as one combo tab",
                                                 leadingIcon: "rectangle.split.2x1") { self.glue(tab.id, beside: left.id) })
                }
            }
            if tab.spec.terminal != nil, store.den(of: tab)?.running == true {
                options.append(CommandOption(title: "Reattach Tab", subtitle: tab.spec.title,
                                             description: "Attach to the tab's den again, as a newly started dense would",
                                             leadingIcon: "arrow.triangle.2.circlepath") { self.reattach(tab) })
            }
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
    /// its tags as "#tag", and finds it by a pasted link to one of its links (see
    /// `Space.linkPrefix`), such as its PR. Collapsed Spaces show their subspaces here. The archived Spaces
    /// come last, greyed out and found by "archived" too; opening one brings it back. Each
    /// row shows its whole path, "space / subspace / subsubspace", rather than indenting.
    /// The Spaces shown most recently come first, but for the selected one, which is already
    /// in front: the first, selected when the palette opens, is the Space shown before this
    /// one, so ⌘K and Return go back and forth between two Spaces. The palette keeps this
    /// order among the Spaces that match a query equally well.
    func openOptions(look: TerminalLook) -> [CommandOption] {
        let rank = Dictionary(recentSpaces.enumerated().map { ($1, $0 + 1) }) { $1 }
        let rows = [false, true].flatMap { archived in
            Self.allRows(archived: archived).map { row -> (CommandOption, Int) in
                let option = Self.option(row.space, look: look, archived: archived) {
                    archived ? self.unarchiveSpace(row.space) : self.select(row.space)
                }
                return (option, row.space.id == selected ? 0 : rank[row.space.id] ?? 0)
            }
        }
        // Stable: unvisited Spaces keep the sidebar's order.
        return rows.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
    }

    /// Every Space but the archived ones, to pick the one a new Space goes under. The
    /// top-level Spaces come first, so they win when they match a query as well as a
    /// subspace does: "p" puts Personal first. Making a top-level Space comes last.
    func parentOptions(look: TerminalLook) -> [CommandOption] {
        let rows = Self.allRows(archived: false)
        let ordered = rows.filter { $0.depth == 0 } + rows.filter { $0.depth > 0 }
        return ordered.map { row in
            Self.option(row.space, look: look, archived: false) { self.newSpace(parent: row.space) }
        } + [CommandOption(title: "New Top-Level Space", leadingIcon: "plus.rectangle.on.folder") {
            self.newSpace(parent: nil)
        }]
    }

    /// Every Space, this machine's then each Host's, in the sidebar's order, with the
    /// collapsed Spaces' subspaces too, each once: not the gathered copies.
    private static func allRows(archived: Bool) -> [Space.Row] {
        let store = SpaceStore.shared
        return ([nil] + store.hostNames.map(Optional.some)).flatMap { host in
            Space.rows(store.spaces(on: host, archived: archived).map { space in
                var space = space
                space.spec.collapsed = nil
                return space
            }).filter { !$0.gathered }
        }
    }

    /// A Space as a palette row, drawn as in the sidebar with its whole path.
    private static func option(_ space: Space, look: TerminalLook, archived: Bool,
                               action: @escaping () -> Void) -> CommandOption {
        let path = path(space, in: SpaceStore.shared.spaces)
        let tags = space.spec.tags.map { $0.map { "#" + $0 }.joined(separator: " ") }
        return CommandOption(
            title: title(space),
            subtitle: path,
            description: archived ? ["archived", tags].compactMap { $0 }.joined(separator: " ") : tags,
            row: AnyView(SpaceRow(space: space, look: look, cell: look.cell,
                                  title: [path, title(space)].compactMap { $0 }.joined(separator: " / "))
                .opacity(archived ? 0.5 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(Font(look.font))),
            links: space.links,
            action: action)
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
