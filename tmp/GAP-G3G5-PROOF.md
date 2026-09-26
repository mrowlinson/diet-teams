# GAP-G3G5 PROOF — call banner+ring (G3), Focus default-on (G5)

- Base: main @ 778c540 (verified `git rev-parse` before worktree create).
- Branch: lanes/gap-g3g5, worktree tmp/wt-gap-g3g5.
- Scope: G3+G5 only. No CallKit (G4 deferred, untouched).

## G3 accepts (audit: "app minimized, incoming call → UNNotification banner w/ Accept/Decline + audible ring until answered/timeout ≤ CallRingPolicy.timeout")

1. Category + actions in Notifier.setup:
   `swift/Sources/OstMacCore/Notifier.swift:108` registers `OmCallInfo.category`
   (`swift/Sources/OstMacCore/CallNotify.swift:21-53`: OM_CALL + OM_CALL_ACCEPT foreground / OM_CALL_DECLINE destructive).
   Same category added to `SystemNotificationCenter.post` (`Notifications.swift:101`) — that call rewrites the whole
   category set on every message post, so without it any message would strip call banners of their buttons.
2. Incoming phase → Notifier: `CallStore` CombineLatest($phase,$call) (`CallView.swift:112-115`) drives
   `syncRing(phase:call:)` (`:299`); inviting+incoming fires `onIncomingRing` once per call id (`:300-314`).
   App assigns hooks live-only (`App.swift:955-966` → `Notifier.postCall`, `Notifier.withdrawCall` on `onRingEnded`).
   Outgoing legs never ring; repeat ingests never re-post (rung-id guard).
3. Audible ring: `CallRinger` (`CallNotify.swift:62-88`) = NSSound loop (Glass→Ping→Tink fallback), `loops=true`,
   start idempotent, nil-sound headless = silent no-op. Started/stopped ONLY by phase transitions: answer (→active),
   decline/end (→idle), dismiss (→ended), timeout `checkTimeout` vs `CallRingPolicy.timeoutSecs=45` (→ended),
   clearEnded (→idle) — every exit from inviting stops the loop by construction. Banner itself posts SILENT
   (`Notifier.swift:173-189`) so banner + ring never double-play.
4. Decline-from-banner: `NcDelivery.route` call arm (`NcDelivery.swift:127-140`: accept/decline/click →
   acceptCall/declineCall/showCall) → shared delegate `MessageNotifications.dispatch` (`Notifications.swift:326-338`)
   broadcasts `.omNotif*Call` → App observers (`App.swift:986-1000`: accept→`call.accept()`, decline→`call.end()`
   which counts an ended ring as a decline, click→`NSApp.activate`). `Notifier` delegate fallback wired too
   (`App.swift:2238-2243`, `Notifier.swift:218-228`) for flipped install order.
5. Banner pixels: NOT captured — env block. System notification auth + a live signed-in call leg are required;
   prior notif-live proof already established banner pixels BLOCKED by system auth (env, not code). Covered instead by:
   category-shape test (actions == [Accept, Decline]), hook-once tests, route/dispatch broadcast tests.

## G5 accepts (audit: "default ON fresh installs; Focus ON → focusActive==true live log; parser failure → Diagnostics error, fails open")

1. Default ON: `FocusSync.swift:84-85` (absent key → true; stored choice always wins, upgrades keep their setting).
2. Live log line: `refresh()` prints `[focus-sync] focusActive=<bool>` on flips, `probe error: <msg>` on new failures,
   `probe recovered` on recovery (`FocusSync.swift:109-123`). Change-only — idle 2s ticks stay silent.
3. Failure → Diagnostics, never stuck-quiet: fail-open kept (`focusActive=false` + `error` set); status lines now show
   the probe error EVEN with sync off (`SettingsView.swift:746-754`, `DiagnosticsView.swift:439-445`) — never hidden
   behind the toggle. Settings copy updated (default-on help + description, `SettingsView.swift:373-377`).
4. Live observation (this machine, macOS 27.0): real `~/Library/DoNotDisturb/DB/Assertions.json` (9021B, header
   version 8) holds invalidation-only keys, no `storeActiveAssertionRecords` → focusActive=false. Matches the
   Focus-OFF unit fixture. OPEN: Focus-ON shape still inferred (enabling Focus needs interactive GUI; not toggled
   from agent shell), 2nd OS version needs a second machine.

## Design decisions (consumed)

- Call banners ignore quiet/Focus: time-critical "never miss calls" beats "never buzzed" (documented at postCall).
- Decline = `call.end()` (existing decline accounting reused, no new path).
- No ringer/hooks in demo (shots stay silent/banner-free); nil ringer = silent (tests headless-safe).
- `@Published` emits in willSet: syncRing takes the DELIVERED (phase,call) pair, never self re-reads (commented).

## Tests

- New `swift/Tests/OstMacCoreTests/GapG3G5Tests.swift`: 15 tests (7 ring/banner-hook, 5 category/route/dispatch, 3 Focus).
- Updated `FocusSyncTests.swift`: `testDefaultsOn` (was testDefaultsOff), `testSyncOffIgnoresFocus` now sets OFF explicitly.
- Gate: `swift test` — 2244 total (Core 2185 + MCP 33 + Diet 26), 0 failures, 1 pre-existing skip. `swift build --product OstMac` links.
- Note: worktree needed the prebuilt `rust/.../target/release/libostmac_core.a` copied from main checkout (gitignored
  build artifact, target/ not in git) before any link step could succeed.

## Files changed

- NEW `swift/Sources/OstMacCore/CallNotify.swift` (OmCallInfo + CallRinging/CallRinger/FakeRinger).
- `swift/Sources/OstMacCore/CallView.swift` (ringer/hooks/syncRing).
- `swift/Sources/OstMacCore/Notifier.swift` (category, postCall/withdrawCall, delegate routes, closures).
- `swift/Sources/OstMacCore/Notifications.swift` (route cases, dispatch broadcasts, category set).
- `swift/Sources/OstMacCore/NcDelivery.swift` (callID + route arm).
- `swift/Sources/OstMac/App.swift` (live-only ringer/hooks, 3 observers, Notifier fallbacks).
- `swift/Sources/OstMacCore/FocusSync.swift` (default ON, log lines).
- `swift/Sources/OstMac/SettingsView.swift`, `swift/Sources/OstMac/DiagnosticsView.swift` (error-first + copy).
- NEW `swift/Tests/OstMacCoreTests/GapG3G5Tests.swift`; `FocusSyncTests.swift` (2 tests).
