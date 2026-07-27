#!/bin/bash
# Builds libmarkive_ffi.a (release) and copies it where the Swift builds
# expect it (macos/.libs, gitignored). Called by run.sh and the Xcode
# pre-build phase; run manually before a bare `swift build` / `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build -p markive-ffi --release --manifest-path ../Cargo.toml

mkdir -p .libs
cp ../target/release/libmarkive_ffi.a .libs/
