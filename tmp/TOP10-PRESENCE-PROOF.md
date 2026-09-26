# TOP10-PRESENCE proof (lane `lanes/top10-presence`)

Base: main @ 008b27f. Scope: presence/status ONLY.

## Demand

MS Teams Q&A carries 100+ dupes of two complaints: random flips to Away,
and DND melting into Away. Teams' server aggregates presence across every
device/session with opaque precedence and recomputes on its own schedule —
the client can only be truthful about its own slice. This lane does that.

## Built

1. Local activity truth — `PresenceActivity` + `PresenceTruthStore.activity()`.
   Idle seconds from `CGEventSource.secondsSinceLastEventType(combinedSession,
   any-input)` (same counter as Screen Saver / Energy Saver), lock/asleep via
   `com.apple.screenIsLocked/Unlocked` + `NSWorkspace willSleep/didWake`.
   Auto-Away threshold 300s = Teams parity. Probe fails open (unknown→active,
   never auto-Aways blind).
2. Manual status lock — `PresenceLock` + durations 15m/1h/4h/until-off
   (picker menu, Settings → Truthful presence). Persisted; launch-swept.
   While locked: idle logic skipped, schedule held via `externalHold`
   (unspent — current window fires on lift), server drift reasserted
   (60s cooldown + PT1H grant refresh).
3. Precedence shown — `PresencePrecedence` (DND > Busy/call > Away >
   Available > Offline; ties → newest → this Mac) rendered verbatim in
   Diagnostics → Presence truth (`PresenceDevicesView`): rule table + live
   rows (This Mac vs Teams server aggregate + adopted) + winner + why +
   drift flag.
4. No silent flips — every auto-change (idle, back, schedule, server,
   reaffirm, lock-expiry) appended to a capped (30) session log shown in
   Diagnostics; reversible ones raise a 12s undo toast (`PresenceUndoToast`
   under the call banner + Diagnostics Undo button). Manual picker echoes
   are labeled manual via chained `manualSetHook` (15s grace), never "server".

Ghost respected: auto-sets + lock fires hold (counted in ghost store, no
phantom log entries); nothing auto-retries behind ghost.

## Accept

- `testAcceptDNDLockHoldsVsIdleAndCalendar`: lock DND 1h with calendar
  window active + Mac idle → zero non-DND writes for the hour; injected
  server Away reasserted to DND (server + reaffirm entries, no undo while
  locked); past expiry the lock lifts and the schedule fires Busy.
- Precedence view lists devices: `testDevicesListThisMacAndServer`
  (This Mac + Teams server rows, adopted extras, built-in protection).

## Verify (worktree tmp/wt-top10-presence, swift/)

- `swift build` → Build complete.
- `swift test --filter PresenceTruthTests` → 31 tests, 0 failures.
- `swift test --filter PresenceTests|PresenceScheduleTests|GhostModeTests|
  DiagnosticsTests` → 56 tests, 0 failures.
- Full gate parent-side post-merge (box pegged).

## Touch list

- NEW `swift/Sources/OstMacCore/PresenceTruth.swift` (lock, activity,
  log, devices, precedence, store, toast, diag rows, devices view)
- NEW `swift/Tests/OstMacCoreTests/PresenceTruthTests.swift` (31 tests)
- `PresenceSchedule.swift`: `externalHold` gate + `onApplied` hook
- `Presence.swift`: picker lock section (status + duration)
- `App.swift`: `presenceTruth` store, hook wiring, 2s tick, lock/sleep
  observers, toast mount, sign-out clear, Settings pass-through
- `DiagnosticsView.swift`: Presence truth section (rows + devices)
- `SettingsView.swift`: Truthful presence section (toggles + lock)
