#!/bin/sh
# Assemble OstMacSpike.app from the SPM release binary. Rust first.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release
APP="$ROOT/swift/.build/release/OstMacSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OstMacSpike "$APP/Contents/MacOS/OstMacSpike"
cp AppInfo.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
echo "APP=$APP"
du -sh "$APP"
