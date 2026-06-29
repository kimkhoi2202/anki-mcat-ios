#!/usr/bin/env bash
# Rebuilds AnkiCore.xcframework from rslib (the shared Anki Rust core).
# Requires: rustup with iOS targets, Xcode, and the desktop fork present at
# ../../anki-desktop/main (rslib is consumed via a path dependency).
set -euo pipefail
cd "$(dirname "$0")"

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
for t in "${TARGETS[@]}"; do
  echo "==> building $t"
  cargo build --target "$t"
done

rm -rf AnkiCore.xcframework
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/debug/libankicore_ffi.a" -headers include \
  -library "target/aarch64-apple-ios-sim/debug/libankicore_ffi.a" -headers include \
  -library "target/aarch64-apple-darwin/debug/libankicore_ffi.a" -headers include \
  -output AnkiCore.xcframework

echo "==> AnkiCore.xcframework rebuilt"
