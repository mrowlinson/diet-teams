# TOP10-MENUBAR proof — lean startup + menu-bar mode

Lane: `lanes/top10-menubar` off main @ 008b27f. Scope: launch/menu-bar only.

## What shipped

1. **Opt-IN login item** (default off). `LoginItemStore` (ServiceManagement
   seam): init performs zero service calls; only the Settings toggle's
   explicit `set(_:)` registers/unregisters — the app can never re-enable
   itself. Settings → Account → Startup section, error row on failure.
2. **Menu-bar extra**: presence dot + unread count label; popover with own
   status, top-8 unread rows (tap opens the chat in the main window via
   the existing `.omNotifOpenChat` funnel + activate), Open + Quit.
3. **Deferred meeting-engine load**: (a) meeting list no longer fetched on
   the launch path — first Meetings-window open triggers it (that scene
   already `refresh()`es on appear; nothing else reads the list);
   (b) A/V + Call window contents wrapped in `LazyView` (SwiftUI runs
   every scene closure at launch — this was constructing capture models
   and enumerating cameras pre-join); (c) `CameraCapture.session` now
   allocated on first media use; (d) `AppState.screenShare` lazy.
4. **Cold-start probe**: `[coldstart]` timeline (`appstate.init`,
   `content.open`, `startup.done`, `chat.first-open`) + `media.inits-
   before-join` counter, flushed line by line. `--coldstart-quit` proof
   hook exits cleanly after join-ready (30s cap).

## Cold-start numbers (`--demo-rich --coldstart-quit`, exit 0)

Before = deferrals reverted, probe kept. Box load ~773 during runs, so
wall-clock is noise-dominated (a later after-run hit content.open
+513.5ms); the structural deltas are the claim.

| mark | before | after |
|---|---|---|
| appstate.init | +432.2ms | +346.5ms |
| content.open | +1144.0ms | +1791.8ms |
| chat.first-open (join-ready) | +1204.4ms | +1828.8ms |
| media.inits-before-join | 1 (screenshare.model) | **0** |

Launch-path removals (before → after): meeting-list fetch 1 → 0 (live
saves a network RTT off the critical path), ScreenShareModel 1 → 0,
CameraCapture() 2 → 0, `videoDevices()` DiscoverySession queries 2 → 0,
AVCaptureSession allocations 0 → 0 (now pinned unallocated by test).

Raw logs: `tmp/coldstart-before.log`, `tmp/coldstart-after.log`.

## Accept checks

- `media.inits-before-join: 0` on fresh launch (log above).
- Login toggle round-trips register/unregister; init touches nothing —
  pinned by `LeanStartupTests` (fake service call log).
- Menu-bar shows presence: live app queried over accessibility —
  `menu bar item Better Teams, Available, 0 unread` (demo own presence
  + wired unread total). Screenshots unavailable in this session (black
  frame — no display access); **owner must eyeball the extra + Startup
  toggle before merge** (launch: `Top10Menubar.app --demo-rich
  --show-settings`; note: lane test bundle id `dev.ostmac.Top10Menubar`
  was used to dodge the crash-restore modal — delete `~/Library/Saved
  Application State/dev.ostmac.Top10Menubar.savedState` if re-running).

## Tests

- New `swift/Tests/OstMacCoreTests/LeanStartupTests.swift`: 15 tests,
  15 pass (login-item contract ×5, probe ×3, menu math ×3, camera
  deferral ×2, LazyView ×1, meetings on-demand ×1).
- Neighbors: MeetingsTests + AvPanelTests + CallTests +
  CallExperienceTests = 82 tests, 0 failures.
- `swift build`: complete (only pre-existing Swift-6-mode warnings in
  untouched `Notifications.swift`). Full gate: parent-side post-merge.
