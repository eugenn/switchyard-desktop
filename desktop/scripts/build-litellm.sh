#!/bin/sh
set -eu
DESKTOP="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$DESKTOP/.." && pwd)"
cd "$ROOT"
STAMP="$(cat "$DESKTOP/runtime/litellm/requirements.lock" "$DESKTOP/runtime/litellm/launcher.py" "$0" | shasum -a 256 | cut -d ' ' -f 1)"
if [ -f "$DESKTOP/build/litellm-runtime/.build-stamp" ] \
    && [ "$(cat "$DESKTOP/build/litellm-runtime/.build-stamp")" = "$STAMP" ] \
    && "$DESKTOP/build/litellm-runtime/bin/python3.12" -I "$DESKTOP/build/litellm-runtime/launcher.py" --check >/dev/null 2>&1; then
    exit 0
fi
uv python install 3.12.10 --install-dir "$DESKTOP/build/python-download"
# Use the private build download, never a system or user Python installation.
case "$(uname -m)" in
    arm64) PLATFORM=aarch64 ;;
    x86_64) PLATFORM=x86_64 ;;
    *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
PYTHON_SOURCE="$DESKTOP/build/python-download/cpython-3.12.10-macos-$PLATFORM-none"
RUNTIME="$DESKTOP/build/litellm-runtime"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
/usr/bin/ditto "$PYTHON_SOURCE" "$RUNTIME"
export MACOSX_DEPLOYMENT_TARGET=14.0
# orjson is built from source, and cargo's release profile strips the result with the
# cctools strip, which leaves a mis-aligned LINKEDIT string pool that macOS 27's dyld
# refuses to load. Keeping the symbols costs ~46 KB and keeps the module loadable.
export CARGO_PROFILE_RELEASE_STRIP=none
uv pip install --python "$RUNTIME/bin/python3.12" \
    --target "$RUNTIME/lib/python3.12/site-packages" \
    --require-hashes --no-binary orjson -r "$DESKTOP/runtime/litellm/requirements.lock"
# Entry points are run through Python directly, so no absolute pip shebang is used.
cp "$DESKTOP/runtime/litellm/launcher.py" "$RUNTIME/launcher.py"
PYTHONDONTWRITEBYTECODE=1 "$RUNTIME/bin/python3.12" -I "$RUNTIME/launcher.py" --check

python3 "$DESKTOP/scripts/verify-macos-target.py" "$RUNTIME"
printf "%s\n" "$STAMP" > "$RUNTIME/.build-stamp"
