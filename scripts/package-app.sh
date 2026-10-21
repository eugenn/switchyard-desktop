#!/bin/sh
# Builds a complete app bundle. Release signing is configured by the caller.
set -eu

usage() {
    cat <<'USAGE'
Usage: scripts/package-app.sh [options]

Options:
  --configuration debug|release  Swift build configuration (default: release)
  --output PATH                  Destination for the .app bundle (required)
  --signing-identity ID          codesign identity, or - for ad-hoc signing
  --hardened-runtime             Enable hardened runtime during signing
USAGE
}

CONFIGURATION=release
OUTPUT=
SIGNING_IDENTITY=
HARDENED_RUNTIME=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --configuration)
            CONFIGURATION="${2:?missing configuration}"
            shift 2
            ;;
        --output)
            OUTPUT="${2:?missing output path}"
            shift 2
            ;;
        --signing-identity)
            SIGNING_IDENTITY="${2:?missing signing identity}"
            shift 2
            ;;
        --hardened-runtime)
            HARDENED_RUNTIME=1
            shift
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

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "Unsupported build configuration: $CONFIGURATION" >&2
        exit 64
        ;;
esac

PRODUCT=SwitchyardDesktopApp
EXECUTABLE=switchyard-desktop
INFO_PLIST=Info.plist

if [ -z "$OUTPUT" ] || [ -z "$SIGNING_IDENTITY" ]; then
    usage >&2
    exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$SIGNING_IDENTITY" != "-" ]; then
    if [ "$HARDENED_RUNTIME" -ne 1 ]; then
        echo "A distributable build must enable the hardened runtime." >&2
        exit 65
    fi
    python3 "$ROOT/scripts/update-switchyard.py" --verify --release --check-published
fi
# shellcheck disable=SC1091
. "$ROOT/Resources/AppVersion.env"

case "$SWITCHYARD_DESKTOP_VERSION" in
    *[!0-9.]*|'') echo "Invalid SWITCHYARD_DESKTOP_VERSION" >&2; exit 65 ;;
esac
case "$SWITCHYARD_DESKTOP_BUILD" in
    *[!0-9]*|'') echo "Invalid SWITCHYARD_DESKTOP_BUILD" >&2; exit 65 ;;
esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"

"$ROOT/scripts/build-switchyard.sh"
"$ROOT/scripts/build-litellm.sh"
swift build -c "$CONFIGURATION" --product "$PRODUCT"
BUILD_PRODUCTS="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BUILD_PRODUCTS/$PRODUCT"
RESOURCE_BUNDLE="$BUILD_PRODUCTS/switchyard-desktop_SwitchyardDesktopKit.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Missing SwitchyardDesktopKit resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources" "$OUTPUT/Contents/Helpers"
/usr/bin/ditto "$ROOT/build/litellm-runtime" "$OUTPUT/Contents/Resources/LiteLLM"
cp "$ROOT/build/switchyard-target/release/switchyard-server" "$OUTPUT/Contents/Helpers/switchyard-server"
cp "$ROOT/vendor/switchyard-source.json" "$OUTPUT/Contents/Resources/switchyard-source.json"
mkdir -p "$OUTPUT/Contents/Resources/Licenses/Switchyard"
mkdir -p "$OUTPUT/Contents/Resources/Licenses/SwitchyardDesktop"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$OUTPUT/Contents/Resources/Licenses/SwitchyardDesktop/"
cp "$ROOT/vendor/switchyard/LICENSE" "$ROOT/vendor/switchyard/NOTICE" "$OUTPUT/Contents/Resources/Licenses/Switchyard/"
python3 "$ROOT/scripts/collect-rust-licenses.py" "$OUTPUT/Contents/Resources/Licenses/Rust"
cp "$BINARY" "$OUTPUT/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/$INFO_PLIST" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/Resources/COPYRIGHT.txt" "$OUTPUT/Contents/Resources/COPYRIGHT.txt"
cp "$ROOT/Resources/PRIVACY.txt" "$OUTPUT/Contents/Resources/PRIVACY.txt"
cp "$ROOT/Resources/THIRD-PARTY-NOTICES.txt" \
    "$OUTPUT/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$ROOT/Resources/AppIcon.icns" "$OUTPUT/Contents/Resources/AppIcon.icns"
cp -R "$RESOURCE_BUNDLE" "$OUTPUT/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SWITCHYARD_DESKTOP_VERSION" \
    "$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SWITCHYARD_DESKTOP_BUILD" \
    "$OUTPUT/Contents/Info.plist"
/usr/bin/plutil -lint "$OUTPUT/Contents/Info.plist" >/dev/null

python3 "$ROOT/scripts/sign-bundle.py" "$OUTPUT" "$SIGNING_IDENTITY"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$OUTPUT"
"$ROOT/scripts/verify-bundle.sh" "$OUTPUT"
echo "Built $OUTPUT"
