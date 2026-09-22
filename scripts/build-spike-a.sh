#!/bin/sh
# Build OstMacSpikeA.app (lane A): release staticlib + SwiftUI shell.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_TGT="${CARGO_TARGET_DIR:-$ROOT/tmp/target-a-lib}"
export CARGO_TARGET_DIR="$LIB_TGT"

cargo build --release --manifest-path "$ROOT/rust/ostmac-a/Cargo.toml"
LIB="$LIB_TGT/release/libostmac_a.a"

APP="$ROOT/tmp/build-a/OstMacSpikeA.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/swift/OstMacSpikeA/Info.plist" "$APP/Contents/Info.plist"

swiftc -O -parse-as-library -o "$APP/Contents/MacOS/OstMacSpikeA" \
  "$ROOT/swift/OstMacSpikeA/OstMacSpikeA.swift" \
  -I "$ROOT/swift/OstMacSpikeA/CRustA" \
  -L "$(dirname "$LIB")" -lostmac_a \
  -framework Security -framework CoreFoundation -framework SystemConfiguration

echo "built: $APP"
du -sh "$APP"
ls -l "$APP/Contents/MacOS/OstMacSpikeA"
