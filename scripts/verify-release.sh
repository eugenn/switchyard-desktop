#!/bin/sh
# Verifies the local trust properties required before publishing a public DMG.
set -eu

usage() {
    echo "Usage: scripts/verify-release.sh --app PATH --dmg PATH" >&2
}

APP=
DMG=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            APP="${2:?missing app path}"
            shift 2
            ;;
        --dmg)
            DMG="${2:?missing dmg path}"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

if [ -z "$APP" ] || [ -z "$DMG" ] || [ ! -d "$APP" ] || [ ! -f "$DMG" ]; then
    usage
    exit 66
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/update-switchyard.py" --verify --release --check-published \
    --manifest "$APP/Contents/Resources/switchyard-source.json"
"$ROOT/scripts/verify-bundle.sh" "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP"
/usr/bin/codesign --verify --strict --verbose=4 "$DMG"
/usr/bin/xcrun stapler validate "$APP"
/usr/bin/xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
/usr/sbin/spctl --assess --type open --verbose=4 "$DMG"

echo "Release verification passed for $APP and $DMG"
