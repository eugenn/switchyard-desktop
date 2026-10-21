#!/bin/sh
# Local checks shared by developer and public builds. No account or network needed.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: scripts/verify-bundle.sh PATH.app}"
HELPER="$APP/Contents/Helpers/switchyard-server"
# Read the executable name from the packaged application.
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
test -x "$APP/Contents/MacOS/$EXECUTABLE"
test -x "$HELPER"
# The resource bundle is flat under SwiftPM and a macOS bundle under Xcode's build system.
ICONS="$APP/Contents/Resources/switchyard-desktop_SwitchyardDesktopKit.bundle"
test -f "$ICONS/AppIcon.png" || test -f "$ICONS/Contents/Resources/AppIcon.png"
test -f "$APP/Contents/Resources/switchyard-source.json"
test -f "$APP/Contents/Resources/Licenses/Switchyard/LICENSE"
test -f "$APP/Contents/Resources/Licenses/Rust/index.json"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --strict "$HELPER"
/usr/bin/codesign --verify --deep --strict "$APP"
# Neither executable may load a library from a developer checkout or Homebrew.
for executable in "$APP/Contents/MacOS/$EXECUTABLE" "$HELPER"; do
    /usr/bin/otool -L "$executable" | /usr/bin/tail -n +2 | while read -r library remainder; do
        case "$library" in
            /System/Library/*|/usr/lib/*|@rpath/libswift*.dylib) ;;
            *) echo "Unexpected runtime dependency: $library" >&2; exit 1 ;;
        esac
    done
done
# Launch the shipped helper in a clean environment, independent of cargo and PATH.
/usr/bin/env -i PATH=/usr/bin:/bin HOME="${HOME}" "$HELPER" \
    --config "$ROOT/configs/switchyard/smoke.toml" --dry-run
RUNTIME="$APP/Contents/Resources/LiteLLM"
/usr/bin/env -i PATH=/usr/bin:/bin HOME="${HOME}" "$RUNTIME/bin/python3.12" -I "$RUNTIME/launcher.py" --check
python3 "$ROOT/scripts/verify-macos-target.py" "$APP"
python3 "$ROOT/scripts/smoke-bundle.py" "$APP"
printf 'Bundle verification passed: %s\n' "$APP"
