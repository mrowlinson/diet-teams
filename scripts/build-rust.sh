#!/bin/sh
# Build vendored ost + ostmac-core staticlib (release).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cargo build --release --manifest-path "$ROOT/rust/ost/Cargo.toml"
cargo build --release --manifest-path "$ROOT/rust/ostmac-core/Cargo.toml"
ls -lh "$ROOT/rust/ost/target/release/teams-cli" \
       "$ROOT/rust/ostmac-core/target/release/libostmac_core.a"
