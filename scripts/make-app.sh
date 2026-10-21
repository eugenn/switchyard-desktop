#!/bin/sh
# Compatibility wrapper for the non-distributable developer build.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/build-dev-app.sh" "$@"
