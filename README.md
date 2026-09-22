# OstMac — ost (Teams) on macOS: spike + scaffold

Proves `ost` (Rust Teams client) builds and runs on macOS, carves a minimal
embeddable core (auth device-code + chat list + Trouter events), and drives it
from a minimal SwiftUI shell over a C ABI (JSON over the boundary).

## Layout

- `rust/ost/` — vendored ost sources (+ `OSTMAC-PATCHES.md`: what changed, why)
- `rust/ostmac-core/` — FFI crate (`staticlib` + `rlib`), C ABI in
  `swift/Sources/COstMac/include/ostmac_core.h`
- `swift/` — SPM package: `COstMac` (headers), `OstMacCore` (Swift wrapper),
  `OstMacChatList` (chat sidebar + `ChatSelection` contract for the
  conversation lane), `OstMac` (integrated app: sidebar + conversation +
  live feed), `OstMacCoreTests`
- `scripts/` — `build-rust.sh`, `build-app.sh`, `test.sh`
- `docs/shots/` — viewed screenshots (TUI + SwiftUI shell)

## Build / run

```sh
./scripts/test.sh        # rust tests + swift tests (builds rust first)
./scripts/build-app.sh   # OstMac.app
open swift/.build/release/OstMac.app
open swift/.build/release/OstMac.app --args --demo  # offline canned data
```

Prereqs: Xcode CLT (`swift`, `xcodebuild`), `cargo`. No Linux-only features
(`audio`, `video-capture`) — default features only.

## Measured (2026-09-21, arm64, macOS 27)

- ost builds: yes (1 upstream fix required, see PATCHES). Warnings: 104
  pre-existing (unused imports/vars). Binaries: debug 35M, release 10M.
- TUI: renders unsigned after stay-open patch; sidebar/messages/compose/help
  all work; all data paths need sign-in. Shots: `docs/shots/tui-*.png`.
- Lib spike: device start+poll (real URL+code), chat list (unsigned → clean
  error JSON), Trouter channel (roundtrip tested; live connect needs sign-in).
- SwiftUI shell: window opens, core 0.1.0 init=0, status visible, device flow
  driven to code prompt. `.app` 7.6M, idle RSS ~94MB (status screen + poll
  loop). Shots: `docs/shots/spike-*.png`.
- Tests: `cargo test` ostmac-core 6/6, ost 91+91/91+91, `swift test` 6/6.

## Sign-in boundary

`login` / device-code runs to the browser prompt and stops there — completing
sign-in needs the owner in a browser. After sign-in, re-run chats + Trouter
connect to exercise the live paths.

## FFI choice

C ABI + handwritten header (cbindgen-fallback equivalent) instead of
swift-bridge: fewer moving parts for the spike, JSON keeps the boundary
version-tolerant. Revisit swift-bridge if the surface grows past ~15 calls.
