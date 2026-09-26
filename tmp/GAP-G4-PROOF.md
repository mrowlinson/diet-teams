# GAP-G4-PROOF — CallKit (L)

- Lane: `lanes/gap-g4` (worktree `tmp/wt-gap-g4`), base main @ 541e9f8.
- Spec: `tmp/TOPTEN-AUDIT.md` G4 — "incoming call shows native macOS call
  UI; responds to system mute/answer; recents integrate; DND/Focus handled
  by OS policy."

## 1. Verdict: CallKit provider API does not exist on macOS

Full CXProvider/CXCallController integration is unshippable, proven at the
SDK level (MacOSX27.0.sdk, Xcode):

| Symbol | Header | Line |
|---|---|---|
| CXProviderDelegate | CallKit.framework/Headers/CXProvider.h | :38, :40 `API_UNAVAILABLE(macos, tvos)` |
| CXProvider | CallKit.framework/Headers/CXProvider.h | :79 `API_UNAVAILABLE(macos, tvos)` |
| CXCallController | CallKit.framework/Headers/CXCallController.h | :16 `API_UNAVAILABLE(macos, tvos)` |
| CXCallObserver | CallKit.framework/Headers/CXCallObserver.h | :15, :22 `API_UNAVAILABLE(macos, tvos)` |

Compile probe (file declaring `CXProviderDelegate` + `CXProvider` +
`CXCallController`): `swiftc -typecheck` fails with
`error: 'CXProvider' is unavailable in macOS`. Any static reference is a
build error — no entitlement, no plist key, no runtime trick changes that.

Runtime anomaly (documented, not relied on): `NSClassFromString("CXProvider")`
returns nil in a plain process but non-nil under the XCTest harness
(harness image-loading noise). Unusable in both — no linkable symbol — so
availability is a compile-time gate, never a class probe
(`CallKitSupport.swift:46`).

## 2. Consequence: G3 is the permanent macOS route

Brief said "keep G3 as fallback, do not delete." Reality is stronger: G3
(UNNotification banner + NSSound ring) is the ONLY macOS path, so it stays
primary. Nothing G3 deleted; `CallRouting` (`CallKitSupport.swift:62-68`)
pins the rule `.callKit iff providerAvailable else .g3Banner` so a future
macOS that ships CXProvider flips one predicate. Live route on this box:
`.g3Banner` (test-pinned).

## 3. Accept-criteria mapping (what G4 shipped vs what is impossible)

- Native macOS call UI: IMPOSSIBLE — no system call UI exists for
  third-party VoIP on macOS. The G3 UNNotification banner with
  Accept/Decline IS the native answer surface; kept as-is.
- System answer: SHIPPED (G3, kept) — banner Accept/Decline actions route
  via `NcDelivery` to `CallStore.accept()/end()`.
- System mute: SHIPPED (G4, new) — `CallRinger` consults `mutedCheck`
  (`CallNotify.swift:109`) before every start; the app installs the live
  CoreAudio probe (`App.swift:1171`, `SystemAudioMute.isOutputMuted`,
  `CallKitSupport.swift:77`, `AudioObjectGetPropertyData` `:84,95`,
  `kAudioDevicePropertyMute` `:92`). Muted output = no ring, banner still
  posts. Probe fails open (any error reads unmuted).
- DND/Focus by OS policy: SHIPPED (G4, pinned) — call banner content now
  built solely by `OmCallInfo.makeContent` (`CallNotify.swift:52`) with
  explicit `interruptionLevel = .active` (`:59`); Focus/DND suppress by
  system policy, no app-side quiet check. (Explicit .active == previous
  default: zero behavior change, policy now pinned + tested.)
- Recents integrate: IMPOSSIBLE system-side (no API) — in-app CallHistory
  (`CallHistory.swift`, shipped earlier) is the recents surface.

## 4. Files changed

- NEW `swift/Sources/OstMacCore/CallKitSupport.swift` — verdict doc,
  `CallKitSupport` gate, `CallRouting` rule, `SystemAudioMute` probe.
- `swift/Sources/OstMacCore/CallNotify.swift` — `OmCallInfo.makeContent`
  builder; `CallRinger.mutedCheck`; G4 header note.
- `swift/Sources/OstMacCore/Notifier.swift` — `postCall` via `makeContent`.
- `swift/Sources/OstMac/App.swift:1168-1171` — live ringer gets the mute probe.
- NEW `swift/Tests/OstMacCoreTests/GapG4Tests.swift` — 10 tests.

## 5. Tests (observed this session)

- `swift build`: complete (needed a Rust staticlib rebuild in-worktree:
  the copied `libostmac_core.a` predated `ostmac_files_recents`; rebuilt
  via `cargo build --release -p ostmac-core`, then build clean).
- `GapG4Tests`: 10/10 pass (verdict gate, routing both legs + live leg,
  content contract, stable id, muted/unmuted/nil ringer, probe runs,
  G3-path-still-posts).
- Regressions: `GapG3G5Tests` 15/15, `NotifTests` 21/21,
  `CallExperienceTests` 29/29 — all pass.

## 6. Shots: none (non-visual lane)

No pixel changed: banner content identical (explicit .active == default),
ringer change is audio-only (silence into muted output). G3's banner shots
stand; nothing new to capture. Zero real data involved either way.
