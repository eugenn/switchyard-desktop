#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/update-switchyard.py" --verify
export CARGO_TARGET_DIR="$ROOT/build/switchyard-target"
cd "$ROOT/vendor/switchyard"

# macOS 14 is the app minimum, and it has to reach the compiled C in ring and
# aws-lc-sys as well as the Rust link step. Exporting MACOSX_DEPLOYMENT_TARGET
# would also apply to the host proc-macro crates rustc loads during the build,
# and rustc then fails to load them ("can't find crate for `thiserror_impl`"),
# so the floor is scoped to the build target instead: an explicit --target
# keeps host units on the toolchain's own defaults.
HOST="$(rustc -vV | awk '/^host: /{print $2}')"
UNDERSCORED="$(printf '%s' "$HOST" | tr '-' '_')"
UPPERCASED="$(printf '%s' "$UNDERSCORED" | tr 'a-z' 'A-Z')"
export "CARGO_TARGET_${UPPERCASED}_RUSTFLAGS=-C link-arg=-mmacosx-version-min=14.0"
export "CFLAGS_${UNDERSCORED}=-mmacosx-version-min=14.0"
export "CXXFLAGS_${UNDERSCORED}=-mmacosx-version-min=14.0"
cargo build --locked --release --target "$HOST" -p switchyard-server

# Everything else in the repo reads one canonical path, so the per-target build
# is published there.
mkdir -p "$CARGO_TARGET_DIR/release"
cp "$CARGO_TARGET_DIR/$HOST/release/switchyard-server" "$CARGO_TARGET_DIR/release/switchyard-server"

# cargo/ld's own linker-signed signature is rejected outright by taskgated on
# some macOS versions ("Code Signature Invalid"), which kills the binary
# before main() runs. Packaging re-signs the copy it bundles anyway
# (sign-bundle.py); this ad-hoc re-sign is what lets this script's own smoke
# check, and a dev running the raw binary, launch it at all.
codesign --sign - --force "$CARGO_TARGET_DIR/release/switchyard-server"
"$CARGO_TARGET_DIR/release/switchyard-server" --config "$ROOT/configs/switchyard/smoke.toml" --dry-run
