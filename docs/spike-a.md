# Lane A notes (duplicate spike, same session)

Parallel lane A ran the same spike while the canonical lane (`rust/ostmac-core`,
SPM `swift/`, `docs/shots/`) was built. Kept for the record: independent
implementation + measurements. Lane A screenshots were removed by the sibling's
scratch cleanup after viewing; GUI proof now rests on `docs/shots/` (viewed).

## Lane A artifacts

- `rust/ostmac-a/` — FFI crate (`ostmac_version/init/auth_start/chats/
  trouter_start`, C ABI, JSON envelopes). Tests: `tests/bridge.rs`
  (6 pass + 1 live ignored, all through the real FFI + callbacks).
- `swift/OstMacSpikeA/` — SwiftUI shell + `CRustA` modulemap, built with
  `swiftc` into `tmp/build-a/OstMacSpikeA.app` (not committed).
- `scripts/build-spike-a.sh`, `build-ost-a.sh`, `test-a.sh`.

## Lane A measured (arm64, macOS 27)

- ost builds: YES (with the 2 shared vendored patches). Debug 36,767,384 B,
  release 10,856,784 B. Warnings ~105 (vendored, pre-existing).
- ost TUI (viewed 21:04): no-auth main view, `?` help overlay, clean `q` quit,
  status `Auth: Token expired and no refresh token`. Login printed a real
  device code (`BS2HNZE52`) and polled (viewed 21:07; killed after shot).
- `libostmac_a.a` (release) 35,708,664 B, 0 warnings.
- `OstMacSpikeA.app` 11 MB (exe 11,713,056 B). Window opened, core 0.1.0
  initialised (viewed 21:24). Idle: RSS ~85 MB, footprint phys 29 MB
  (peak 35 MB), CPU 0.0%.
- Bridge choice: hand-written C ABI (swift-bridge skipped: codegen dep
  avoided for a spike; same interop proven).

## Unresolved (lane A)

- Owner sign-in at login.microsoft.com/device (chats/trouter live paths).
- In-app button states for lane A's own shell (screen locked 21:26+);
  FFI ops proven headless instead (`test-a.sh [--live]`).
