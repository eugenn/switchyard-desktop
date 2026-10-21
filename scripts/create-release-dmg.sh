#!/bin/sh
# Creates a signed, notarized, stapled DMG. It never falls back to ad-hoc signing.
set -eu

usage() {
    cat <<'USAGE'
Usage: SWITCHYARD_DESKTOP_SIGNING_IDENTITY='Developer ID Application: ...' \
       SWITCHYARD_DESKTOP_NOTARY_PROFILE='notarytool-keychain-profile' \
       scripts/create-release-dmg.sh [--output-directory PATH]

The signing identity and notarytool keychain profile are required. Credentials,
Apple IDs, and certificate exports must remain outside this repository.
USAGE
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIRECTORY="$ROOT/dist"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-directory)
            OUTPUT_DIRECTORY="${2:?missing output directory}"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

APP_NAME="switchyard-desktop.app"
VOLNAME="switchyard-desktop"
ARTIFACT_STEM="switchyard-desktop"

: "${SWITCHYARD_DESKTOP_SIGNING_IDENTITY:?Set SWITCHYARD_DESKTOP_SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${SWITCHYARD_DESKTOP_NOTARY_PROFILE:?Set SWITCHYARD_DESKTOP_NOTARY_PROFILE to a notarytool keychain profile.}"

case "$SWITCHYARD_DESKTOP_SIGNING_IDENTITY" in
    "Developer ID Application: "*) ;;
    *)
        echo "SWITCHYARD_DESKTOP_SIGNING_IDENTITY must be a Developer ID Application identity." >&2
        exit 65
        ;;
esac

# shellcheck disable=SC1091
. "$ROOT/Resources/AppVersion.env"
ARTIFACT_NAME="${ARTIFACT_STEM}-${SWITCHYARD_DESKTOP_VERSION}-${SWITCHYARD_DESKTOP_BUILD}-$(uname -m).dmg"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-desktop-release.XXXXXX")"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT INT TERM

APP="$WORK_DIRECTORY/$APP_NAME"
APP_ARCHIVE="$WORK_DIRECTORY/${ARTIFACT_STEM}.zip"
DMG_STAGING="$WORK_DIRECTORY/dmg-root"
DMG="$WORK_DIRECTORY/$ARTIFACT_NAME"

"$ROOT/scripts/package-app.sh" \
    --configuration release \
    --output "$APP" \
    --signing-identity "$SWITCHYARD_DESKTOP_SIGNING_IDENTITY" \
    --hardened-runtime

# Staple the app before it is copied into the final DMG so offline app checks work.
/usr/bin/ditto -c -k --keepParent "$APP" "$APP_ARCHIVE"
/usr/bin/xcrun notarytool submit "$APP_ARCHIVE" \
    --keychain-profile "$SWITCHYARD_DESKTOP_NOTARY_PROFILE" \
    --wait
/usr/bin/xcrun stapler staple "$APP"

mkdir -p "$DMG_STAGING"
/usr/bin/ditto "$APP" "$DMG_STAGING/$APP_NAME"
ln -s /Applications "$DMG_STAGING/Applications"

/usr/bin/hdiutil create \
    -volname "$VOLNAME $SWITCHYARD_DESKTOP_VERSION" \
    -srcfolder "$DMG_STAGING" \
    -format UDZO \
    -ov "$DMG" >/dev/null
/usr/bin/codesign --force --timestamp --sign "$SWITCHYARD_DESKTOP_SIGNING_IDENTITY" "$DMG"
/usr/bin/xcrun notarytool submit "$DMG" \
    --keychain-profile "$SWITCHYARD_DESKTOP_NOTARY_PROFILE" \
    --wait
/usr/bin/xcrun stapler staple "$DMG"

"$ROOT/scripts/verify-release.sh" --app "$APP" --dmg "$DMG"

mkdir -p "$OUTPUT_DIRECTORY"
mv "$DMG" "$OUTPUT_DIRECTORY/$ARTIFACT_NAME"
echo "Release artifact: $OUTPUT_DIRECTORY/$ARTIFACT_NAME"
