#!/bin/sh
# Assemble OstMac.app from the SPM release binary. Rust first.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMac
APP="$ROOT/swift/.build/release/OstMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OstMac "$APP/Contents/MacOS/OstMac"
cp AppInfo-OstMac.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
    echo "signed: $CODESIGN_IDENTITY"
fi
echo "APP=$APP"
du -sh "$APP"
