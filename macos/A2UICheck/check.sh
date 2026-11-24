#!/bin/sh
# Checks A2UI messages, one JSON object per line, in the files named (or stdin), against
# dense's catalog as this checkout has it: what an Extension sends must pass before it goes
# to a dense built from here. It builds only the catalog and the A2UI library, at the
# versions the app pins, not dense: the first run takes a few minutes, then seconds.
#
#   macos/A2UICheck/check.sh panels.jsonl
#   macos/A2UICheck/check.sh --dowt     # dowt's panels, from its main on GitHub
set -e
pkg=$(cd "$(dirname "$0")" && pwd)
cp "$pkg/../Ghostty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$pkg/"
swift build --package-path "$pkg" --force-resolved-versions -q
if [ "$1" = --dowt ]; then
    # To a file first: a failed download in a pipe would pass as "ok: 0 messages".
    curl -fsSL -o "$pkg/.build/dowt-panels.jsonl" https://raw.githubusercontent.com/mkmik/dowt/main/testdata/panels.jsonl
    "$pkg/.build/debug/a2ui-check" "$pkg/.build/dowt-panels.jsonl"
else
    "$pkg/.build/debug/a2ui-check" "$@"
fi
