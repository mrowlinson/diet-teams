#!/bin/sh
# Assemble OstMacAuth.app (om-authux lane: sign-in window) from the
# SPM release binary. Rust first. Signs when CODESIGN_IDENTITY is set.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMacAuth
APP="$ROOT/swift/.build/release/OstMacAuth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OstMacAuth "$APP/Contents/MacOS/OstMacAuth"
cp AppInfo-Auth.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
    echo "signed: $CODESIGN_IDENTITY"
fi
echo "APP=$APP"
du -sh "$APP"
