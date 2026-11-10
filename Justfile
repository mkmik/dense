default:
    @just --list

# Build an Apple Silicon release into macos/build/ReleaseLocal/Dense.app
build:
    zig build -Doptimize=ReleaseFast -Dxcframework-target=native

# Build a release and pack it into zig-out/Dense.dmg and zig-out/Dense.tar.gz
release: build
    #!/usr/bin/env bash
    set -euo pipefail
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' EXIT
    cp -R macos/build/ReleaseLocal/Dense.app "$staging/"
    ln -s /Applications "$staging/Applications"
    mkdir -p zig-out
    hdiutil create -volname Dense -srcfolder "$staging" -ov -format UDZO zig-out/Dense.dmg
    tar -czf zig-out/Dense.tar.gz -C "$staging" Dense.app

# Build a release and install it as /Applications/Dense.app (a running Dense offers to restart into it)
install: build
    rm -rf /Applications/Dense.app
    ditto macos/build/ReleaseLocal/Dense.app /Applications/Dense.app
