#!/bin/sh
# Build-time setup only. The GUI never downloads or installs a runtime.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$ROOT/scripts/build-switchyard.sh"
"$ROOT/scripts/build-litellm.sh"
echo "Xcode runtime ready. Open Package.swift and run SwitchyardDesktopApp on My Mac."
