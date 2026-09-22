#!/bin/bash
# Install release Diet Teams.app to /Applications (builds first if missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/tmp/Diet Teams.app"
if [[ ! -x "$APP/Contents/MacOS/OstMac" ]]; then
    "$ROOT/scripts/package.sh"
fi
rm -rf "/Applications/Diet Teams.app"
cp -R "$APP" "/Applications/Diet Teams.app"
codesign --verify --verbose=1 "/Applications/Diet Teams.app"
echo "installed: /Applications/Diet Teams.app"
du -sh "/Applications/Diet Teams.app"
