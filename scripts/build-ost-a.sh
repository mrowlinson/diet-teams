#!/bin/sh
# Build vendored ost (lane A target dir).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/tmp/target-a}"
cargo build --manifest-path "$ROOT/rust/ost/Cargo.toml" "$@"
ls -l "$CARGO_TARGET_DIR/debug/teams-cli"
