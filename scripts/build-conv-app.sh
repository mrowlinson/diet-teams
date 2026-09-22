#!/bin/sh
# Assemble OstMacConv.app (om-conv lane: one-conversation window) from the
# SPM release binary. Rust first. Signs when CODESIGN_IDENTITY is set.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMacConv
APP="$ROOT/swift/.build/release/OstMacConv.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OstMacConv "$APP/Contents/MacOS/OstMacConv"
cp AppInfo-Conv.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
    echo "signed: $CODESIGN_IDENTITY"
fi
echo "APP=$APP"
du -sh "$APP"
