#!/bin/bash
# Builds libmarkive_ffi.a and copies it where the Swift builds expect it
# (macos/.libs, gitignored). Called by run.sh and the Xcode pre-build phase;
# run manually before a bare `swift build` / `swift test`.
#
# Debug/dev builds are host-arch. Release (the sandboxed universal app) needs
# both slices, selected via --universal or CONFIGURATION=Release from the
# Xcode script phase.
set -euo pipefail
cd "$(dirname "$0")/.."

universal=false
if [[ "${1:-}" == "--universal" || "${CONFIGURATION:-}" == "Release" ]]; then
    universal=true
fi

mkdir -p .libs
if $universal; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
    cargo build -p markive-ffi --release --target aarch64-apple-darwin --manifest-path ../Cargo.toml
    cargo build -p markive-ffi --release --target x86_64-apple-darwin --manifest-path ../Cargo.toml
    lipo -create \
        ../target/aarch64-apple-darwin/release/libmarkive_ffi.a \
        ../target/x86_64-apple-darwin/release/libmarkive_ffi.a \
        -output .libs/libmarkive_ffi.a
else
    cargo build -p markive-ffi --release --manifest-path ../Cargo.toml
    cp ../target/release/libmarkive_ffi.a .libs/
fi
