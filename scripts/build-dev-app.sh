#!/bin/sh
# Produces an ad-hoc-signed local bundle only; it is never a release artifact.
set -eu

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 64
fi
APP="$ROOT/build/switchyard-desktop.app"

"$ROOT/scripts/package-app.sh" \
    --configuration "$CONFIGURATION" \
    --output "$APP" \
    --signing-identity -

echo "Developer bundle: $APP"
echo "This bundle uses an ad-hoc signature and must not be distributed."
