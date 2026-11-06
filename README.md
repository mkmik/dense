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

Milestone 1: the app builds and runs as plain Ghostty, named `dense.app`,
with the bundle ID `pub.mkm.dense`. It can run next to Ghostty. It does not
check for updates, because Ghostty's updates would replace it with Ghostty.

## Build

Needs Zig 0.17 and Xcode 26 (Xcode 26 also runs on macOS 15).

    zig build -Doptimize=ReleaseFast -Dxcframework-target=native
    open zig-out/dense.app

`zig build run` builds a debug app and starts it with logs on stderr.

## Config

dense reads the same config files as Ghostty, in `~/.config/ghostty/` and
`~/Library/Application Support/com.mitchellh.ghostty/`. libghostty builds
those paths from its own fixed ID, not from the app's bundle ID, so the new
bundle ID does not change them.

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
