#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/update-switchyard.py" --verify --release --check-published
printf '%s\n' 'Source provenance verified. This does not verify an installer, signatures or notarization.'
