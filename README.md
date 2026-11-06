# dense

dense is a macOS terminal app built from a fork of the
[Ghostty](https://github.com/ghostty-org/ghostty) app. It uses Ghostty's code
and reads Ghostty's config file, so it looks and behaves like Ghostty.

The plan is to add one thing Ghostty does not have: a sidebar that shows a
tree of spaces. Each space has its own tabs, and each tab is a terminal
attached to a [den](https://github.com/mkmik/den). Spaces and tabs are stored
in [dennet](https://github.com/mkmik/dennet), so other tools can create and
change them.

## Status

Milestone 1: the app builds and runs as plain Ghostty, named `Dense.app`,
with the bundle ID `pub.mkm.dense`. It can run next to Ghostty. It does not
check for updates, because Ghostty's updates would replace it with Ghostty.

Milestone 2: each window has a sidebar on the left showing the tree of
Spaces stored in dennet. It updates as soon as a Space changes. It cannot
change anything yet. dense connects to dennet's socket at
`~/.local/state/dennet/dennet.sock`; if it can't, the sidebar says why and
dense keeps trying every two seconds.

Milestone 3 (in progress): clicking a Space shows a tab bar above the
terminal, right of the sidebar, with one tab per terminal Surface in
`order`. Each tab runs `den attach` for its Den. Tabs out of view keep
running, so switching back is instant. Closing a tab, or `den attach`
exiting, drops the tab's terminal but keeps the window; clicking the tab
attaches again. dense remembers the selected Space and each Space's front
tab (in its user defaults), and a new window opens on them. The plain
terminal a window starts with is closed as soon as a tab is shown.

There are no macOS window tabs. Ghostty's tab commands act on the Space's
tabs, wherever they come from (key bindings, menus, the command palette,
AppleScript, Shortcuts, Services, dropping on the Dock icon):

- new tab, and the + in the tab bar: creates a Den and a Surface in dennet,
  starts the den with `den apply` (dennet does not start dens yet), and
  shows the tab. It opens in the current tab's directory.
- go to tab N, next, previous, last: switches tabs.
- move tab: writes the new `order` of the Space's Surfaces to dennet.
- close tab: as above, detaches the tab; the Den and Surface stay.

A tab whose Surface has no `title` shows the terminal's own title.

## Build

Needs Zig 0.17 and Xcode 26 (Xcode 26 also runs on macOS 15).

    zig build -Doptimize=ReleaseFast -Dxcframework-target=native
    open zig-out/Dense.app

`zig build run` builds a debug app and starts it with logs on stderr.

## Config

dense uses Ghostty's config file format, so a Ghostty `config.ghostty`
can be copied over as is. It reads its own files, not Ghostty's:
`$XDG_CONFIG_HOME/dense/config.ghostty` (`~/.config/dense/` when
`XDG_CONFIG_HOME` is not set), then
`~/Library/Application Support/pub.mkm.dense/config.ghostty`. Both are
loaded when both exist, and the second wins where they set the same key.
User themes go in `~/.config/dense/themes/`. These folders are set in
libghostty (`src/config/file_load.zig`, `src/config/theme.zig`,
`src/os/macos.zig`).

## Following Ghostty

This repository holds Ghostty's full history, and dense's changes sit on top
of a Ghostty release tag. To move to a new release:

    git fetch ghostty refs/tags/v1.5.0:refs/tags/ghostty-v1.5.0
    git merge ghostty-v1.5.0

Merge such branches with a merge commit, never a squash: a squash drops
Ghostty's history, and then every later merge from Ghostty conflicts.

Ghostty's own docs are in [HACKING.md](HACKING.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT, like Ghostty. See [LICENSE](LICENSE).
