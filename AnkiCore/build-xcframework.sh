#!/usr/bin/env bash
# Rebuilds AnkiCore.xcframework from rslib (the shared Anki Rust core).
# Requires: rustup with iOS targets, Xcode, and the desktop fork present at
# ../../anki-desktop/main (rslib is consumed via a path dependency).
set -euo pipefail
cd "$(dirname "$0")"

# rslib's i18n build script gathers Anki's translation catalogs from the
# desktop fork's `ftl/core-repo` + `ftl/qt-repo` submodules. On a fresh clone
# those are empty and the build panics with a NotFound in rslib/i18n/gather.rs,
# so initialize them (shallow) if they're missing.
RSLIB_CHECKOUT="../../anki-desktop/main"
if [ ! -e "$RSLIB_CHECKOUT/ftl/core-repo/core" ]; then
  echo "==> initializing translation submodules in $RSLIB_CHECKOUT"
  git -C "$RSLIB_CHECKOUT" submodule update --init --depth 1 ftl/core-repo ftl/qt-repo
fi

# Pin the minimum OS to match the app so the linker doesn't warn that the Rust
# objects were built for a newer OS than the app links against (AnkiApp targets
# iOS 16; AnkiKit targets macOS 13). Without these, cargo/rustc default to the
# current SDK version, producing one "built for newer version" warning per .o.
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=13.0

# Force blake3 to recompile so its hand-written NEON C object always picks up the
# deployment target above. The `cc` crate doesn't treat IPHONEOS_DEPLOYMENT_TARGET
# as a cache key, so without this a deployment-target change can leave a stale .o
# built for the newer SDK — producing a "built for newer version" linker warning.
cargo clean -p blake3 >/dev/null 2>&1 || true

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
for t in "${TARGETS[@]}"; do
  echo "==> building $t (release)"
  cargo build --release --target "$t"
done

rm -rf AnkiCore.xcframework
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/libankicore_ffi.a" -headers include \
  -library "target/aarch64-apple-ios-sim/release/libankicore_ffi.a" -headers include \
  -library "target/aarch64-apple-darwin/release/libankicore_ffi.a" -headers include \
  -output AnkiCore.xcframework

echo "==> AnkiCore.xcframework rebuilt"
