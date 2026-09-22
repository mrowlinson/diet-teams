#!/bin/sh
# Test lib spike (lane A target dir). Add --live for the device-code test.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/tmp/target-a-lib}"
if [ "${1:-}" = "--live" ]; then
  cargo test --manifest-path "$ROOT/rust/ostmac-a/Cargo.toml" -- --ignored
else
  cargo test --manifest-path "$ROOT/rust/ostmac-a/Cargo.toml"
fi
