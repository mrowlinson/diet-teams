#!/bin/bash
# Install release OstMac.app to /Applications (builds first if missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/tmp/OstMac.app"
if [[ ! -x "$APP/Contents/MacOS/OstMac" ]]; then
    "$ROOT/scripts/package.sh"
fi
rm -rf /Applications/OstMac.app
cp -R "$APP" /Applications/OstMac.app
codesign --verify --verbose=1 /Applications/OstMac.app
echo "installed: /Applications/OstMac.app"
du -sh /Applications/OstMac.app
