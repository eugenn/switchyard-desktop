#!/bin/sh
# Local install test artifact. Public releases use create-release-dmg.sh.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Resources/AppVersion.env"

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 64
fi
APP_NAME="switchyard-desktop.app"
VOLNAME="switchyard-desktop"
ARTIFACT_STEM="switchyard-desktop"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-desktop-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT INT TERM
"$ROOT/scripts/package-app.sh" --configuration release \
    --output "$STAGING/$APP_NAME" --signing-identity -
ln -s /Applications "$STAGING/Applications"
printf '%s\n' 'Local development build. Ad-hoc signed; not notarized for public distribution.' > "$STAGING/LOCAL-BUILD.txt"
mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/${ARTIFACT_STEM}-${SWITCHYARD_DESKTOP_VERSION}-${SWITCHYARD_DESKTOP_BUILD}-$(uname -m)-local.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
printf 'Local installer: %s\n' "$DMG"
