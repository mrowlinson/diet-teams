#!/bin/sh
# Assemble Diet Teams.app from the SPM release binary. Rust first.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMac
APP="$ROOT/swift/.build/release/Diet Teams.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OstMac "$APP/Contents/MacOS/OstMac"
cp OstMac-Info.plist "$APP/Contents/Info.plist"
cp Resources/OstMac.icns "$APP/Contents/Resources/OstMac.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
    echo "signed: $CODESIGN_IDENTITY"
fi
echo "APP=$APP"
du -sh "$APP"
